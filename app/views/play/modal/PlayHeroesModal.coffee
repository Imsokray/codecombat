ModalView = require 'views/kinds/ModalView'
template = require 'templates/play/modal/play-heroes-modal'
buyGemsPromptTemplate = require 'templates/play/modal/buy-gems-prompt'
CocoCollection = require 'collections/CocoCollection'
ThangType = require 'models/ThangType'
SpriteBuilder = require 'lib/sprites/SpriteBuilder'
AudioPlayer = require 'lib/AudioPlayer'
utils = require 'lib/utils'
BuyGemsModal = require 'views/play/modal/BuyGemsModal'
Purchase = require 'models/Purchase'

module.exports = class PlayHeroesModal extends ModalView
  className: 'modal fade play-modal'
  template: template
  id: 'play-heroes-modal'

  events:
    'slide.bs.carousel #hero-carousel': 'onHeroChanged'
    'change #option-code-language': 'onCodeLanguageChanged'
    'click #close-modal': 'hide'
    'click #confirm-button': 'saveAndHide'
    'click .unlock-button': 'onUnlockButtonClicked'
    'click .buy-gems-prompt-button': 'onBuyGemsPromptButtonClicked'
    'click': 'onClickedSomewhere'

  shortcuts:
    'left': -> @$el.find('#hero-carousel').carousel('prev') if @heroes.models.length and not @$el.hasClass 'secret'
    'right': -> @$el.find('#hero-carousel').carousel('next') if @heroes.models.length and not @$el.hasClass 'secret'
    'enter': 'saveAndHide'

  constructor: (options) ->
    super options
    options ?= {}
    @confirmButtonI18N = options.confirmButtonI18N ? "common.save"
    @heroes = new CocoCollection([], {model: ThangType})
    @heroes.url = '/db/thang.type?view=heroes'
    @heroes.setProjection ['original','name','slug','soundTriggers','featureImage','gems','heroClass','description','components','extendedName','unlockLevelName','i18n']
    @heroes.comparator = 'gems'
    @listenToOnce @heroes, 'sync', @onHeroesLoaded
    @supermodel.loadCollection(@heroes, 'heroes')
    @stages = {}
    @session = options.session
    @initCodeLanguageList options.hadEverChosenHero
    @heroAnimationInterval = setInterval @animateHeroes, 2500

  onHeroesLoaded: ->
    @formatHero hero for hero in @heroes.models

  formatHero: (hero) ->
    hero.name = utils.i18n hero.attributes, 'extendedName' # or whatever the property name ends up being
    hero.name ?= utils.i18n hero.attributes, 'name'
    hero.description = utils.i18n hero.attributes, 'description'
    hero.unlockLevelName = utils.i18n hero.attributes, 'unlockLevelName'
    original = hero.get('original')
    hero.locked = not me.ownsHero(original)
    hero.purchasable = hero.locked and (original in (me.get('earned')?.heroes ? []))
    hero.class = (hero.get('heroClass') or 'warrior').toLowerCase()
    hero.stats = hero.getHeroStats()

  getRenderData: (context={}) ->
    context = super(context)
    context.heroes = @heroes.models
    context.level = @options.level
    context.codeLanguages = @codeLanguageList
    context.codeLanguage = @codeLanguage = @options?.session?.get('codeLanguage') ? me.get('aceConfig')?.language ? 'python'
    context.confirmButtonI18N = @confirmButtonI18N
    context.visibleHero = @visibleHero
    context

  afterRender: ->
    super()
    return unless @supermodel.finished()
    heroes = @heroes.models
    @$el.find('.hero-indicator').each ->
      heroID = $(@).data('hero-id')
      hero = _.find heroes, (hero) -> hero.get('original') is heroID
      $(@).find('.hero-avatar').css('background-image', "url(#{hero.getPortraitURL()})").tooltip()
    @canvasWidth = 313  # @$el.find('canvas').width() # unreliable, whatever
    @canvasHeight = @$el.find('canvas').height()
    heroConfig = @options?.session?.get('heroConfig') ? me.get('heroConfig') ? {}
    heroIndex = Math.max 0, _.findIndex(heroes, ((hero) -> hero.get('original') is heroConfig.thangType))
    @$el.find(".hero-item:nth-child(#{heroIndex + 1}), .hero-indicator:nth-child(#{heroIndex + 1})").addClass('active')
    @onHeroChanged direction: null, relatedTarget: @$el.find('.hero-item')[heroIndex]
    @$el.find('.hero-stat').tooltip()
    @buildCodeLanguages()
    Backbone.Mediator.publish 'audio-player:play-sound', trigger: 'game-menu-open', volume: 1

  rerenderFooter: ->
    @formatHero @visibleHero
    @renderSelectors '#hero-footer'
    @buildCodeLanguages()

  initCodeLanguageList: (hadEverChosenHero) ->
    @codeLanguageList = [
      {id: 'python', name: "Python (#{$.i18n.t('choose_hero.default')})"}
      {id: 'javascript', name: 'JavaScript'}
      {id: 'coffeescript', name: 'CoffeeScript'}
      {id: 'clojure', name: "Clojure (#{$.i18n.t('choose_hero.experimental')})"}
      {id: 'lua', name: "Lua (#{$.i18n.t('choose_hero.experimental')})"}
      {id: 'io', name: "Io (#{$.i18n.t('choose_hero.experimental')})"}
    ]

  onHeroChanged: (e) ->
    direction = e.direction  # 'left' or 'right'
    heroItem = $(e.relatedTarget)
    hero = _.find @heroes.models, (hero) -> hero.get('original') is heroItem.data('hero-id')
    return console.error "Couldn't find hero from heroItem:", heroItem unless hero
    heroIndex = heroItem.index()
    hero = @loadHero hero, heroIndex
    @preloadHero heroIndex + 1
    @preloadHero heroIndex - 1
    @selectedHero = hero unless hero.locked
    @visibleHero = hero
    @rerenderFooter()
    @trigger 'hero-loaded', {hero: hero}

  getFullHero: (original) ->
    url = "/db/thang.type/#{original}/version"
    if fullHero = @supermodel.getModel url
      return fullHero
    fullHero = new ThangType()
    fullHero.setURL url
    fullHero = (@supermodel.loadModel fullHero, 'thang').model
    fullHero

  preloadHero: (heroIndex) ->
    return unless hero = @heroes.models[heroIndex]
    @loadHero hero, heroIndex, true

  loadHero: (hero, heroIndex, preloading=false) ->
    createjs.Ticker.removeEventListener 'tick', stage for stage in _.values @stages
    # TODO: make sure we are going to axe featureImage, then remove this
    if false and featureImage = hero.get 'featureImage'
      $(".hero-item[data-hero-id='#{hero.get('original')}'] canvas").hide()
      $(".hero-item[data-hero-id='#{hero.get('original')}'] .hero-feature-image").show().find('img').prop('src', '/file/' + featureImage)
      @playSelectionSound hero unless preloading
      return hero
    createjs.Ticker.setFPS 30  # In case we paused it from being inactive somewhere else
    if stage = @stages[heroIndex]
      unless preloading
        _.defer -> createjs.Ticker.addEventListener 'tick', stage  # Deferred, otherwise it won't start updating for some reason.
        @playSelectionSound hero
      return hero
    fullHero = @getFullHero hero.get 'original'
    onLoaded = =>
      return unless canvas = $(".hero-item[data-hero-id='#{fullHero.get('original')}'] canvas")
      canvas.show().prop width: @canvasWidth, height: @canvasHeight
      builder = new SpriteBuilder(fullHero)
      movieClip = builder.buildMovieClip(fullHero.get('actions').attack?.animation ? fullHero.get('actions').idle.animation)
      movieClip.scaleX = movieClip.scaleY = canvas.prop('height') / 120  # Average hero height is ~110px tall at normal resolution
      movieClip.regX = -fullHero.get('positions').registration.x
      movieClip.regY = -fullHero.get('positions').registration.y
      movieClip.x = canvas.prop('width') * 0.5
      movieClip.y = canvas.prop('height') * 0.925  # This is where the feet go.
      if fullHero.get('name') is 'Knight'
        movieClip.scaleX *= 0.7
        movieClip.scaleY *= 0.7
      if fullHero.get('name') is 'Potion Master'
        movieClip.scaleX *= 0.9
        movieClip.scaleY *= 0.9
        movieClip.regX *= 1.1
        movieClip.regY *= 1.4
      if fullHero.get('name') is 'Samurai'
        movieClip.scaleX *= 0.7
        movieClip.scaleY *= 0.7
        movieClip.regX *= 1.2
        movieClip.regY *= 1.35
      if fullHero.get('name') is 'Librarian'
        movieClip.regX *= 0.7
        movieClip.regY *= 1.2
      if fullHero.get('name') is 'Sorcerer'
        movieClip.scaleX *= 0.9
        movieClip.scaleY *= 0.9
        movieClip.regX *= 1.15
        movieClip.regY *= 1.3

      stage = new createjs.Stage(canvas[0])
      @stages[heroIndex] = stage
      stage.addChild movieClip
      stage.update()
      movieClip.loop = false
      movieClip.gotoAndPlay 0
      unless preloading
        createjs.Ticker.addEventListener 'tick', stage
        @playSelectionSound hero
      @rerenderFooter()
    if fullHero.loaded
      _.defer onLoaded
    else
      @listenToOnce fullHero, 'sync', onLoaded
    fullHero

  animateHeroes: =>
    return unless @visibleHero
    heroIndex = Math.max 0, _.findIndex(@heroes.models, ((hero) => hero.get('original') is @visibleHero.get('original')))
    @stages[heroIndex]?.children?[0]?.gotoAndPlay? 0

  playSelectionSound: (hero) ->
    return if @$el.hasClass 'secret'
    @currentSoundInstance?.stop()
    return unless sounds = hero.get('soundTriggers')?.selected
    return unless sound = sounds[Math.floor Math.random() * sounds.length]
    name = AudioPlayer.nameForSoundReference sound
    AudioPlayer.preloadSoundReference sound
    @currentSoundInstance = AudioPlayer.playSound name, 1
    @currentSoundInstance

  buildCodeLanguages: ->
    $select = @$el.find('#option-code-language')
    $select.fancySelect().parent().find('.options li').each ->
      languageName = $(@).text()
      languageID = $(@).data('value')
      blurb = $.i18n.t("choose_hero.#{languageID}_blurb")
      $(@).text("#{languageName} - #{blurb}")

  onCodeLanguageChanged: (e) ->
    @codeLanguage = @$el.find('#option-code-language').val()
    @codeLanguageChanged = true


  #- Purchasing the hero

  onUnlockButtonClicked: (e) ->
    e.stopPropagation()
    button = $(e.target).closest('button')
    affordable = @visibleHero.get('gems') <= me.gems()
    if not affordable
      @askToBuyGems button
    else if button.hasClass('confirm')

      purchase = Purchase.makeFor(@visibleHero)
      purchase.save()

      #- set local changes to mimic what should happen on the server...
      purchased = me.get('purchased') ? {}
      purchased.heroes ?= []
      purchased.heroes.push(@visibleHero.get('original'))
      me.set('purchased', purchased)
      me.set('spent', (me.get('spent') ? 0) + @visibleHero.get('gems'))

      #- ...then rerender visible hero
      heroEntry = @$el.find(".hero-item[data-hero-id='#{@visibleHero.get('original')}']")
      heroEntry.find('.hero-status-value').attr('data-i18n', 'play.available').i18n()
      heroEntry.removeClass 'locked purchasable'
      @rerenderFooter()

      Backbone.Mediator.publish 'store:hero-purchased', hero: @visibleHero, heroSlug: @visibleHero.get('slug')
    else
      button.addClass('confirm').text($.i18n.t('play.confirm'))
      @$el.one 'click', (e) ->
        button.removeClass('confirm').text($.i18n.t('play.unlock')) if e.target isnt button[0]

  askToBuyGems: (unlockButton) ->
    if me.getGemPromptGroup() is 'no-prompt'
      return @openModalView new BuyGemsModal()
    @$el.find('.unlock-button').popover 'destroy'
    popoverTemplate = buyGemsPromptTemplate {}
    unlockButton.popover(
      animation: true
      trigger: 'manual'
      placement: 'left'
      content: ' '  # template has it
      container: @$el
      template: popoverTemplate
    ).popover 'show'
    popover = unlockButton.data('bs.popover')
    popover?.$tip?.i18n()

  onBuyGemsPromptButtonClicked: (e) ->
    @openModalView new BuyGemsModal()

  onClickedSomewhere: (e) ->
    return if @destroyed
    @$el.find('.unlock-button').popover 'destroy'


  #- Exiting

  saveAndHide: ->
    hero = @selectedHero.get('original')

    if @session
      changed = @updateHeroConfig(@session, hero)
      if @session.get('codeLanguage') isnt @codeLanguage
        @session.set('codeLanguage', @codeLanguage)
        changed = true
        Backbone.Mediator.publish 'tome:change-language', language: @codeLanguage, reload: true

      @session.patch() if changed

    changed = @updateHeroConfig(me, hero)
    aceConfig = _.clone(me.get('aceConfig')) or {}
    if @codeLanguage isnt aceConfig.language
      aceConfig.language = @codeLanguage
      me.set 'aceConfig', aceConfig
      changed = true

    me.patch() if changed

    @hide()
    @trigger?('confirm-click', hero: @selectedHero)

  updateHeroConfig: (model, hero) ->
    heroConfig = _.clone(model.get('heroConfig')) or {}
    if heroConfig.thangType isnt hero
      heroConfig.thangType = hero
      model.set('heroConfig', heroConfig)
      return true

  onHidden: ->
    super()
    Backbone.Mediator.publish 'audio-player:play-sound', trigger: 'game-menu-close', volume: 1

  destroy: ->
    clearInterval @heroAnimationInterval
    for heroIndex, stage of @stages
      createjs.Ticker.removeEventListener "tick", stage
      stage.removeAllChildren()
    super()
