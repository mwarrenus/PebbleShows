UI = require('ui')
Settings = require('settings')
ajax = require('ajax')
async = require('async')
Emitter = require('emitter')

CONFIG_BASE_URL = 'http://bobby.alessiobogon.com:8020/'
ICON_MENU_UNCHECKED = 'images/icon_menu_unchecked.png'
ICON_MENU_CHECKED = 'images/icon_menu_checked.png'

userDateFormat = "D MMMM YYYY"

console.log "accessToken: #{Settings.option 'accessToken'}"

updatesEmitter = new Emitter()

signInWindow = undefined
shows = undefined

sleep = (ms) ->
  unixtime_ms = new Date().getTime();
  while(new Date().getTime() < unixtime_ms + ms)
    1


traktvRequest = (opt, success, failure) ->
  console.log "traktvRequest: opt: #{JSON.stringify opt}"
  # console.log success
  if typeof opt == 'string'
    opt = if opt.indexOf('http') == 0
      url: opt
    else
      action: opt

  opt.method ?= 'GET'

  if opt.action[0] == '/'
    opt.action = opt.action[1..]

  opt.url ?= "https://api-v2launch.trakt.tv/#{opt.action}"

  accessToken = Settings.option 'accessToken'
  unless accessToken?
    displaySignInWindow()
    return

  ajax
    url: opt.url
    type: 'json'
    headers:
      'trakt-api-version': 2
      'trakt-api-key': '16fc8c04f10ebdf6074611891c7ce2727b4fcae3d2ab2df177625989543085e9'
      Authorization: "Bearer #{accessToken}"
    method: opt.method
    data: opt.data
    success
    (response, status, req) ->
      if status == 401
        console.log "Server says that authorization is required"
        displaySignInWindow()
      console.log "Request failure (#{status} #{method} #{url})"
      failure(response, status, req)

reloadShow = (showID, success, failure) ->
  traktvRequest "/shows/#{showID}/progress/watched",
    (response, status, req) ->
      console.log "Reloading show #{showID}"
      item = i for i in shows when i.show.ids.trakt == showID

      item.next_episode = response.next_episode
      item.seasons = response.seasons
      success(item) if success?
    failure if failure?

getToWatchList = (showList, callback) ->
  showListUpdated = showList[..]
  async.each(
    showListUpdated
    (item, doneItem) ->
      traktvRequest "/shows/#{item.show.ids.trakt}/progress/watched",
        (response, status, req) ->
          # console.log "getToWatchList: asked "
          # console.log "returned: #{JSON.stringify response.seasons}"
          if status != 200
            doneItem(response: response, status: status, req: req)
          item.next_episode = response.next_episode
          item.seasons = response.seasons
          # for season in item.seasons
          #   for episode in season.episodes
          #     episode.completed ?= false
          doneItem()
    (err) ->
      if err?
        console.log "Failed response (#{err.status}): #{err.response}"
        console.log "Request was: #{err.req}"
      # console.log "getToWatchList returning"
      callback(showListUpdated) if callback?
  )

displaySignInWindow = ->
  signInWindow = new UI.Card(
    title: 'Sign-in required'
    body: 'Open the Pebble App and configure Pebble Shows.'
  )
  signInWindow.on 'click', 'back', ->
    # No escape :)
    return
  signInWindow.show()

isNextEpisodeForItemAired = (item) ->
  return false unless item.next_episode?
  if item.next_episode.season > item.seasons.length
    return false
  season = s for s in item.seasons when s.number == item.next_episode.season
  if item.next_episode.number > season.aired
    return false
  true

refreshModels = ->
  traktvRequest 'sync/watched/shows', (response, status, req) ->
    # console.log "Returned shows: #{JSON.stringify shows.map (e)->e.show}"
    getToWatchList response, (toWatchList) ->
      console.log 'toWatchList updated'
      shows = toWatchList
      updatesEmitter.emit 'update', 'shows', shows

modifyCheckState = (opt, success, failure) ->
  # console.log("Check watched! episode: #{JSON.stringify(episode)}")
  console.log "checkWatched: opt: #{JSON.stringify opt}"
  if opt.episodeNumber? and not opt.seasonNumber?
    failure()
    return

  opt.completed ?= true

  request =
    shows: [
      ids: trakt: opt.showID
      seasons: [{
        number: opt.seasonNumber
        episodes: [{
          number: opt.episodeNumber
        }] if opt.episodeNumber
      }] if opt.seasonNumber
    ]

  action = '/sync/history'
  action += '/remove' if opt.completed == false

  # console.log "request: #{JSON.stringify request}"
  traktvRequest
    action: action
    method: 'POST'
    data: request
    (response, status, req) ->
      console.log "Check succeeded: #{JSON.stringify request}"
      # console.log "#{index}: #{key}: #{value}" for key, value of index for index in shows
      for item in shows when item.show.ids.trakt == opt.showID
        for season in item.seasons when not opt.seasonNumber? or season.number == opt.seasonNumber
          for episode in season.episodes when not opt.episodeNumber? or episode.number == opt.episodeNumber
            console.log "Marking as seen #{item.show.title} S#{season.number}E#{episode.number}"
            episode.completed = opt.completed
      success()
    (response, status, req) ->
      console.log "Check FAILURE"
      failure(response, status, req)

compareByKey = (key) ->
  (a, b) ->
    -1 if a[key] < b[key]
    0 if a[key] == b[key]
    1 if a[key] > b[key]

compareByFunction = (keyFunction) ->
  (a, b) ->
    -1 if keyFunction(a) < keyFunction(b)
    0 if keyFunction(a) == keyFunction(b)
    1 if keyFunction(a) > keyFunction(b)

# {
#   episode: 12
#   season: 2
# } or undefined
firstUnwatchedEpisode = (show) ->
  seasons = show.seasons[..]
  seasons.sort compareByKey('number')
  for season in seasons
    # console.log "considering #{show.show.title}, #{JSON.stringify seasons}"
    episodes = season.episodes[..]
    episodes.sort(compareByKey('number'))
    for episode in episodes
      unless episode.completed == true
        return {
          episodeNumber: episode.number
          seasonNumber: season.number
        }

createToWatchMenuItem = (opt) ->
  for key in ['showID', 'episodeTitle', 'seasonNumber', 'episodeNumber', 'completed']
    unless opt[key]?
      console.log "ERROR: #{key} not in #{JSON.stringify opt}"
      return
  {
    title: opt.episodeTitle
    subtitle: "Season #{opt.seasonNumber} Ep. #{opt.episodeNumber}"
    icon: if opt.completed then ICON_MENU_CHECKED else ICON_MENU_UNCHECKED
    data:
      showID: opt.showID
      episodeNumber: opt.episodeNumber
      seasonNumber: opt.seasonNumber
      completed: opt.completed
      isNextEpisodeListed: opt.isNextEpisodeListed
  }

getEpisodeData = (showID, seasonNumber, episodeNumber, callback) ->
  # toWatchMenu.on 'select', (e) ->
  # element = e.item
  item = i for i in shows if i.show.ids.trakt == showID
  season = s for s in item.seasons when s.number == seasonNumber
  episode = e for e in season.episodes when e.number == episodeNumber

  episode.seasonNumber = seasonNumber
  episode.episodeNumber = episodeNumber
  episode.showID = showID

  unless episode.id? and episode.title? and episode.overview?
    traktvRequest "/shows/#{showID}/seasons/#{seasonNumber}/episodes/#{episodeNumber}",
    (response, status, req) ->
      episode.id = response.ids.trakt
      episode.title = response.title

      if episode.overview?
        callback(episode) if callback?
      else
        traktvRequest "/search?id_type=trakt-episode&id=#{episode.id}",
          (response, status, req) ->
            if response
              episode.overview = response[0].episode.overview
            callback(episode) if callback?


  traktvRequest "/shows/#{element.data.showID}/seasons/#{element.data.seasonNumber}/episodes/#{element.data.episodeNumber}",
    (response, status, req) ->
      showTitle = item.show.title for item in shows when item.show.ids.trakt == element.data.showID
      detailedItemCard = new UI.Card(
        title: showTitle
        subtitle: "Season #{element.data.seasonNumber} Ep. #{element.data.episodeNumber}"
        body: "Title: #{response.title}"
        style: 'small'
      )
      detailedItemCard.show()



displayToWatchMenu = (callback) ->
  unless shows?
    handler = (e) ->
      updatesEmitter.off 'updates', 'shows', handler
      displayToWatchMenu(callback)
    updatesEmitter.on 'update', 'shows', handler
    return

  getToWatchMenuItems = ->
    toWatch = []
    for item in shows
      # console.log "Title: #{item.show.title}"
      ep = firstUnwatchedEpisode(item)
      ep_s = if ep? then "S#{ep.seasonNumber}E#{ep.episodeNumber}" else "undefined"
      console.log "First unwatched episode for #{item.show.title} is #{ep_s}"
      # console.log "firstUnwatchedEpisode: #{JSON.stringify ep}}"
      if ep?
        toWatch.push
          title: item.show.title
          subtitle: "Season #{ep.seasonNumber} Ep. #{ep.episodeNumber}"
          icon: ICON_MENU_UNCHECKED
          data:
            episodeNumber: ep.episodeNumber
            seasonNumber: ep.seasonNumber
            showID: item.show.ids.trakt
            completed: false
    toWatch

  # console.log "item: #{key}: #{value}" for key, value of item for item in shows
  # console.log "data: #{JSON.stringify data}"


  toWatchMenu = new UI.Menu
    sections:
      {
        title: item.show.title
        items: [
          createToWatchMenuItem(
            showID: item.show.ids.trakt
            episodeTitle: item.next_episode.title
            seasonNumber: item.next_episode.season
            episodeNumber: item.next_episode.number
            completed: false
          )
        ]
      } for item in shows when isNextEpisodeForItemAired(item)

  toWatchMenu.on 'longSelect', (e) ->
    data = e.item.data
    modifyCheckState
      showID: data.showID
      episodeNumber: data.episodeNumber
      seasonNumber: data.seasonNumber
      completed: not e.item.completed
      () ->
        element = e.item
        isNowCompleted = not element.data.completed

        if isNowCompleted
          element.data.completed = true
          element.icon = ICON_MENU_CHECKED
        else
          element.data.completed = false
          element.icon = ICON_MENU_UNCHECKED

        toWatchMenu.item(e.sectionIndex, e.itemIndex, element)

        if isNowCompleted and not element.isNextEpisodeListed
          # TODO: clean this mess using getEpisodeData
          reloadShow data.showID, (reloadedShow) ->
            console.log "RELOADED ShowID: #{reloadedShow.show.ids.trakt}, title: #{reloadedShow.show.title}"
            if isNextEpisodeForItemAired(reloadedShow) and not element.isNextEpisodeListed
              element.isNextEpisodeListed = true

              newItem = createToWatchMenuItem(
                showID: data.showID
                episodeTitle: reloadedShow.next_episode.title
                seasonNumber: reloadedShow.next_episode.season
                episodeNumber: reloadedShow.next_episode.number
                completed: false
              )
              console.log "toWatchMenu.item(#{e.sectionIndex}, #{e.section.items.length}, #{JSON.stringify newItem}"

              toWatchMenu.item(e.sectionIndex, e.section.items.length, newItem)

  toWatchMenu.on 'select', (e) ->
    element = e.item
    traktvRequest "/shows/#{element.data.showID}/seasons/#{element.data.seasonNumber}/episodes/#{element.data.episodeNumber}",
      (response, status, req) ->
        showTitle = item.show.title for item in shows when item.show.ids.trakt == element.data.showID
        detailedItemCard = new UI.Card(
          title: showTitle
          subtitle: "Season #{element.data.seasonNumber} Ep. #{element.data.episodeNumber}"
          body: "Title: #{response.title}"
          style: 'small'
        )
        detailedItemCard.show()

  toWatchMenu.show()

  callback() if callback?

displayUpcomingMenu = (callback) ->
  startingDate = moment().format('YYYY-MM-DD')
  days = 7
  traktvRequest "/calendars/shows/#{startingDate}/#{days}",
    (response, status, req)->
      sections =
        {
          title: moment(date).format(userDateFormat)
          items:
            {
              title: item.show.title
              subtitle: "S#{item.episode.season}E#{item.episode.number} | #{moment(item.airs_at).format('HH:MM')}"
              data:
                showID: item.show.ids.trakt
                seasonNumber: item.episode.season
                episodeNumber: item.episode.number

            } for item in items
        } for date, items of response
      console.log "sections: #{JSON.stringify sections}"

      upcomingMenu = new UI.Menu(
        sections: sections
      )

      upcomingMenu.show()

      upcomingMenu.on 'select', (e) ->
        element = e.item
        traktvRequest "/shows/#{element.data.showID}/seasons/#{element.data.seasonNumber}/episodes/#{element.data.episodeNumber}",
          (response, status, req) ->
            showTitle = item.show.title for item in shows when item.show.ids.trakt == element.data.showID
            detailedItemCard = new UI.Card(
              title: showTitle
              subtitle: "Season #{element.data.seasonNumber} Ep. #{element.data.episodeNumber}"
              body: "Title: #{response.title}"
              style: 'small'
            )
            detailedItemCard.show()
      callback() if callback?

displayShowsMenu = (callback) ->
  console.log "displayShowsMenu: shows? #{shows?}"
  unless shows?
    handler = (e) ->
      updatesEmitter.off 'updates', 'shows', handler
      displayShowsMenu callback
    updatesEmitter.on 'update', 'shows', handler
    return

  sortedShows = shows[..]
  sortedShows.sort compareByFunction (e) -> moment(e.last_watched_at)

  showsMenu = new UI.Menu
    sections: [{
      items:
        {
          title: item.show.title
          data:
            showID: item.show.ids.trakt
        } for item in sortedShows
    }]

  showsMenu.show()

  showsMenu.on 'select', (e) ->
    data = e.item.data
    item = i for i in shows when i.show.ids.trakt == data.showID
    seasonsMenu = new UI.Menu
      sections: [{
        items:
          {
            title: "Season #{season.number}"
            data:
              showID: data.showID
              seasonNumber: season.number
          } for season in item.seasons
      }]

    seasonsMenu.show()

    seasonsMenu.on 'select', (e) ->
      data = e.item.data
      season = s for s in item.seasons when s.number == data.seasonNumber
      episodesMenu = new UI.Menu
        sections: [{
          items:
            createToWatchMenuItem(
              showID: data.showID
              episodeTitle: "bo"
              seasonNumber: data.seasonNumber
              episodeNumber: episode.number
              completed: false
            ) for episode in season.episodes
        }]
      episodesMenu.show()

  callback() if callback?

initSettings = ->
  Settings.init()
  Settings.config {
    url: CONFIG_BASE_URL
    autoSave: true
  }, (e) ->
    signInWindow.hide()
    refreshModels()

initSettings()

mainMenu = new UI.Menu
  sections: [
    items: [{
      title: 'To watch'
      id: 'toWatch'
    }, {
      title: 'Upcoming episodes'
      id: 'upcoming'
    }, {
      title: 'My shows'
      id: 'myShows'
    }, {
      title: 'Advanced'
      id: 'advanced'
    }]
  ]

mainMenu.on 'select', (e) ->
  switch e.item.id
    when 'toWatch', 'upcoming'
      e.item.subtitle = "Loading..."
      mainMenu.item(e.sectionIndex, e.itemIndex, e.item)

      displayFunction =
        switch e.item.id
          when 'toWatch' then displayToWatchMenu
          when 'upcoming' then displayUpcomingMenu

      displayFunction ->
        delete e.item.subtitle
        mainMenu.item(e.sectionIndex, e.itemIndex, e.item)

    when 'myShows'
      displayShowsMenu()

    when 'advanced'
      advancedMenu = new UI.Menu
        sections: [
          items: [{
            title: 'Reset localStorage'
            action: ->
              localStorage.clear()
              initSettings()
              console.log "Local storage cleared"
          }, {
            title: 'Refresh'
            action: -> refreshModels()
          }]
        ]
      advancedMenu.on 'select', (e) -> e.item.action()
      advancedMenu.show()

mainMenu.show()
refreshModels()
