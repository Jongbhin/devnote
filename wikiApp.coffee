fs = require 'fs'
wiki = require './lib/wiki'
url = require 'url'
debug = (require 'debug')('main')
assert = require 'assert'
mailer = require './lib/mailer'
User = require('./lib/users').User
_ = require 'underscore'
util = require 'util'
__ = (require './lib/i18n').__

ROOT_PATH = '/wikis/'

lastVisits = {}
subscribers = {}

exports.init = (wikiname) ->
  ROOT_PATH += wikiname
  wiki.init wikiname, (err) ->
    if err
      console.log err.message
    else
      data = fs.readFileSync 'frontpage.md'
      wiki.writePage 'frontpage', data, (err) ->
        throw err if err

error404 = (err, req, res, next) ->
  res.statusCode = 404
  res.render '404.jade',
  title: "404 Not Found",
  error: err.message,

error500 = (err, req, res, next) ->
  res.statusCode = 500
  res.render '500.jade',
  title: "Sorry, Error Occurred...",
  error: err.message,

history = (name, req, res) ->
  LIMIT = 30
  handler = (err, commits) ->
    if err
      console.log err
      error404 err, req, res
    else
      res.render 'history',
        title: name
        commits: commits
        limit: LIMIT
  if req.query.until
    offset = parseInt(req.query.offset or 0)
    wiki.queryHistory
      filename: name
      until: req.query.until
      offset: offset
      limit: LIMIT
      handler
  else
    wiki.getHistory name, LIMIT, handler

renderDiff = (diff, inlineCss) ->
  diff.forEach (seg) ->
    klass = 'added' if seg.added
    klass = 'removed' if seg.removed
    if klass
      if (inlineCss)
        color = {'added': '#DFD', 'removed': '#FDD'}[klass]
        attr = "style = 'background-color: #{color}" if color
      else
        attr = "class = '#{klass}'"

    result = _.reduce seg.value.split('\n'),
      (a, b) -> a + '<p ' + (attr or '') + '>' + b + '</p>',
      result

  return result or ''

diff = (name, req, res) ->
  wiki.diff name, [req.query.a, req.query.b], (err, diff) ->
    if err
      error404 err, req, res
    else
      res.render 'diff'
        title: 'Diff'
        name: name
        diff: renderDiff(diff)

# wiki.search 의 검색결과를 HTML로 렌더링한다.
# @param searched wiki.search 의 결과값
# @return result {
#     <pagename>: <html>,
#     ...,
# }
#
renderSearch = (searched) ->
  LIMIT = 120
  result = {}

  for name, matched of searched
    rendered = ''

    if matched instanceof Array
      keyword = matched[0]
      input = matched.input
      index = matched.index
      begin = Math.max(0, index - Math.floor((LIMIT - keyword.length) / 2))
      end = Math.max(begin + LIMIT, begin + keyword.length)

      if begin > 0 then rendered += '...'

      rendered +=
        input.substr(begin, index - begin) +
        '<span class="matched">' + keyword +
        '</span>' +
        input.substr(index + keyword.length, end - (index + keyword.length))

      if end < input.length then rendered += '...'
    else
      if LIMIT < matched.length
        rendered = matched.substr(0, LIMIT) + '...'
      else
        rendered = matched

    result[name] = rendered

  return result

search = (req, res) ->
  keyword = req.query.keyword
  if not keyword
    res.render 'search',
      title: 'Search'
      pages: {}
  else
    wiki.search keyword, (err, pages) ->
      throw err if err
      res.render 'search',
        title: 'Search'
        pages: renderSearch(pages)

exports.getPages = (req, res) ->
  switch req.query.action
    when 'search' then search req, res
    else list req, res

# get wikipage list
list = (req, res) ->
  wiki.getPages (err, pages) ->
    if err
      error404 err, req, res
    else
      res.render 'pages',
        title: 'Pages',
        content: pages

exports.getPage = (req, res) ->
  name = req.params.name
  switch req.query.action
    when 'diff' then diff name, req, res
    when 'history' then history name, req, res
    when 'edit' then edit name, req, res
    else view name, req, res

edit = (name, req, res) ->
  wiki.getPage name, (err, page) ->
    if err
      error404 err, req, res
    else
      res.render 'edit',
        title: 'Edit Page',
        name: name,
        content: page.content

commandUrls = (name) ->
  view: ROOT_PATH + '/pages/' + name,
  new: ROOT_PATH + '/new',
  edit: url.format
    pathname: ROOT_PATH + '/pages/' + name,
    query:
      action: 'edit',
  history: url.format
    pathname: ROOT_PATH + '/pages/' + name,
    query:
      action: 'history',
  delete: url.format
    pathname: ROOT_PATH + '/pages/' + name,
  subscribe: url.format
    pathname: ROOT_PATH + '/subscribes/' + name,

view = (name, req, res) ->
  wiki.getPage name, req.query.rev, (err, page) ->
    if err
      return error404 err, req, res

    subscribed = req.session.user and
      subscribers[name] and
      req.session.user.id in subscribers[name]

    urls = commandUrls name

    renderPage = (lastVisit) ->
      if lastVisit
        urls.diffSinceLastVisit = url.format
          pathname: ROOT_PATH + '/pages/' + name,
          query:
            action: 'diff',
            a: lastVisit.id,
            b: page.commitId,

      options =
        title: name
        content: wiki.render page.content
        commit: page.commit
        isOld: page.isOld
        subscribed: subscribed
        loggedIn: !!req.session.user
        urls: urls
        lastVisit: lastVisit

      res.render 'page', options

    if not req.session.user
      return renderPage()

    userId = req.session.user.id

    if not lastVisits[userId]
      lastVisits[userId] = {}

    lastVisitId = lastVisits[userId][name]
    lastVisits[userId][name] = page.commitId

    if not lastVisitId
      return renderPage()

    if lastVisitId != page.commitId
      # something changed
      return wiki.readCommit lastVisitId,
        (err, commit) ->
          lastVisit =
            date: new Date commit.committer.unixtime * 1000
            id: lastVisitId
          return renderPage lastVisit
    else
      # nothing changed
      return renderPage()

exports.getNew = (req, res) ->
  req.session.flashMessage = 'Flash message test'
  res.render 'new',
    title: 'New Page'
    pageName: '__new_' + new Date().getTime()
    filelist: []

exports.postNew = (req, res) ->
  name = req.body.name
  wiki.writePage name, req.body.body, (err, commitId) ->
    if req.session.user
      userId = req.session.user.id
      if not lastVisits[userId]
        lastVisits[userId] = {}
      lastVisits[userId][name] = commitId

    if subscribers[name]
      # send mail to subscribers of this page.
      wiki.diff name, commitId, ['json', 'unified'], (err, diff) ->
        user = req.session.user

        subject = '[n4wiki] ' + name + ' was edited'
        subject += (' by ' + user.id) if user

        if user
          ids = _.without subscribers[name], user.id
        else
          ids = subscribers[name]

        to = (User.findUserById(id).email for id in ids)

        mailer.send
          to: to
          subject: subject
          text: diff['unified']
          html: renderDiff(diff['json'], true)

    res.redirect ROOT_PATH + '/pages/' + name

exports.postDelete = (req, res) ->
  wiki.deletePage req.params.name, (err) ->
    res.render 'deleted',
      title: req.body.name
      message: req.params.name
      content: 'Page deleted'

exports.postRollback = (req, res) ->
  name = req.params.name
  wiki.rollback name, req.body.id, (err) ->
    wiki.getHistory name, (err, commits) ->
      if err
        error404 err, req, res
      else
        res.contentType 'json'
        res.send
          commits: commits
          name: name
          ids: commits.ids

exports.postSubscribe = (req, res) ->
  name = req.params.name
  if req.session.user
    subscribers[name] = [] if not subscribers[name]
    userId = req.session.user.id
    if not (userId in subscribers[name])
      subscribers[name].push userId

  res.redirect ROOT_PATH + '/pages/' + name

exports.postUnsubscribe = (req, res) ->
  name = req.params.name
  if req.session.user and subscribers[name]
    subscribers[name] = _.without subscribers[name], req.session.user.id

  res.redirect ROOT_PATH + '/pages/' + name
