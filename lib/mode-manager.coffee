_ = require 'underscore-plus'
{Emitter, Range, CompositeDisposable, Disposable} = require 'atom'
Base = require './base'
swrap = require './selection-wrapper'
{moveCursorLeft} = require './utils'

class ModeManager
  mode: 'insert' # Native atom is not modal editor and its default is 'insert'
  submode: null
  replacedCharsBySelection: null

  constructor: (@vimState) ->
    {@editor, @editorElement} = @vimState
    @mode = 'insert'
    @emitter = new Emitter
    @subscriptions = new CompositeDisposable
    @subscriptions.add @vimState.onDidDestroy(@destroy.bind(this))

  destroy: ->
    @subscriptions.dispose()

  isMode: (mode, submode=null) ->
    (mode is @mode) and (submode is @submode)

  # Event
  # -------------------------
  onWillActivateMode: (fn) -> @emitter.on('will-activate-mode', fn)
  onDidActivateMode: (fn) -> @emitter.on('did-activate-mode', fn)
  onWillDeactivateMode: (fn) -> @emitter.on('will-deactivate-mode', fn)
  preemptWillDeactivateMode: (fn) -> @emitter.preempt('will-deactivate-mode', fn)
  onDidDeactivateMode: (fn) -> @emitter.on('did-deactivate-mode', fn)

  # activate: Public
  #  Use this method to change mode, DONT use other direct method.
  # -------------------------
  activate: (newMode, newSubmode=null) ->
    # Avoid odd state(=visual-mode but selection is empty)
    return if (newMode is 'visual') and @editor.isEmpty()

    @emitter.emit('will-activate-mode', mode: newMode, submode: newSubmode)

    if (newMode is 'visual') and @submode? and (newSubmode is @submode)
      [newMode, newSubmode] = ['normal', null]

    @deactivate() if (newMode isnt @mode)

    @deactivator = switch newMode
      when 'normal' then @activateNormalMode()
      when 'operator-pending' then @activateOperatorPendingMode()
      when 'insert' then @activateInsertMode(newSubmode)
      when 'visual' then @activateVisualMode(newSubmode)

    unless newMode is 'visual'
      swrap.clearProperties(@editor)

    @editorElement.classList.remove("#{@mode}-mode")
    @editorElement.classList.remove(@submode)

    [@mode, @submode] = [newMode, newSubmode]

    @editorElement.classList.add("#{@mode}-mode")
    @editorElement.classList.add(@submode) if @submode?

    @vimState.statusBarManager.update(@mode, @submode)
    @vimState.updateCursorsVisibility()

    @emitter.emit('did-activate-mode', {@mode, @submode})

  deactivate: ->
    unless @deactivator?.disposed
      @emitter.emit('will-deactivate-mode', {@mode, @submode})
      @deactivator?.dispose()
      # Remove css class here in-case @deactivate() called solely(occurrence in visual-mode)
      @editorElement.classList.remove("#{@mode}-mode")
      @editorElement.classList.remove(@submode)

      @emitter.emit('did-deactivate-mode', {@mode, @submode})

  # Normal
  # -------------------------
  activateNormalMode: ->
    @vimState.reset()
    # Component is not necessary avaiable see #98.
    @editorElement.component?.setInputEnabled(false)

    # In visual-mode, cursor can place at EOL. move left if cursor is at EOL
    # We should not do this in visual-mode deactivation phase.
    # e.g. `A` directly shift from visua-mode to `insert-mode`, and cursor should remain at EOL.
    for cursor in @editor.getCursors() when cursor.isAtEndOfLine()
      moveCursorLeft(cursor, preserveGoalColumn: true)
    new Disposable

  # Operator Pending
  # -------------------------
  activateOperatorPendingMode: ->
    new Disposable

  # Insert
  # -------------------------
  activateInsertMode: (submode=null) ->
    @editorElement.component.setInputEnabled(true)
    replaceModeDeactivator = @activateReplaceMode() if submode is 'replace'

    new Disposable =>
      replaceModeDeactivator?.dispose()
      replaceModeDeactivator = null

      # When escape from insert-mode, cursor move Left.
      needSpecialCareToPreventWrapLine = @editor.hasAtomicSoftTabs()
      for cursor in @editor.getCursors()
        moveCursorLeft(cursor, {needSpecialCareToPreventWrapLine})

  activateReplaceMode: ->
    @replacedCharsBySelection = new WeakMap
    subs = new CompositeDisposable
    subs.add @editor.onWillInsertText ({text, cancel}) =>
      cancel()
      @editor.getSelections().forEach (selection) =>
        for char in text.split('') ? []
          if (char isnt "\n") and (not selection.cursor.isAtEndOfLine())
            selection.selectRight()
          selectedText = selection.getText()
          selection.insertText(char)

          unless @replacedCharsBySelection.has(selection)
            @replacedCharsBySelection.set(selection, [])
          @replacedCharsBySelection.get(selection).push(selectedText)

    subs.add new Disposable =>
      @replacedCharsBySelection = null
    subs

  getReplacedCharForSelection: (selection) ->
    @replacedCharsBySelection.get(selection)?.pop()

  # Visual
  # -------------------------
  # We treat all selection is initially NOT normalized
  #
  # 1. First we normalize selection
  # 2. Then update selection orientation(=wise).
  #
  # Regardless of selection is modified by vmp-command or outer-vmp-command like `cmd-l`.
  # When normalize, we move cursor to left(selectLeft equivalent).
  # Since Vim's visual-mode is always selectRighted.
  #
  # - un-normalized selection: This is the range we see in visual-mode.( So normal visual-mode range in user perspective ).
  # - normalized selection: One column left selcted at selection end position
  # - When selectRight at end position of normalized-selection, it become un-normalized selection
  #   which is the range in visual-mode.
  activateVisualMode: (submode) ->
    @vimState.assertWithException(submode?, "activate visual-mode without submode")

    for $selection in swrap.getSelections(@editor) when not $selection.hasProperties()
      $selection.saveProperties()

    swrap.normalize(@editor)

    $selection.applyWise(submode) for $selection in swrap.getSelections(@editor)

    @vimState.getLastBlockwiseSelection().autoscroll() if submode is 'blockwise'
    @updateNarrowedState()
    @vimState.updatePreviousSelection()

    new Disposable =>
      swrap.normalize(@editor)

      if @submode is 'blockwise'
        swrap.setReversedState(@editor, true)
      selection.clear(autoscroll: false) for selection in @editor.getSelections()
      @updateNarrowedState(false)

  # Narrow to selection
  # -------------------------
  hasMultiLineSelection: ->
    if @isMode('visual', 'blockwise')
      # [FIXME] why I need null guard here
      not @vimState.getLastBlockwiseSelection()?.isSingleRow()
    else
      not swrap(@editor.getLastSelection()).isSingleRow()

  updateNarrowedState: (value=null) ->
    @editorElement.classList.toggle('is-narrowed', value ? @hasMultiLineSelection())

  isNarrowed: ->
    @editorElement.classList.contains('is-narrowed')

module.exports = ModeManager
