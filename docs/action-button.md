# Action button (iPhone)

Hold the Action button, speak, and what you said is sent to the Peel agent.

## Set up
- Settings > Action Button > Shortcut > Ask Peel.
- Back Tap: Settings > Accessibility > Touch > Back Tap > Shortcut > Ask Peel.
- Siri: "Ask Peel", "Talk to Peel" or "Message Peel".
- Control Center / Lock Screen: add the Shortcuts control and pick Ask Peel. A
  dedicated ControlWidget needs a widget-extension target and is not in this change.

## Flow
`AskPeelIntent` -> `AgentInbox` (`PendingTexts`, in memory, 5 at most, oldest
dropped) -> `RootView.drain` -> `AppModel.send(_:from: .chat(agentChat))` -> the
agent's Sphinx DM. The agent chat is opened first. If the send fails the text
goes back into the agent composer's draft and the chat shows the notice. With
no agent set up, a notice is shown.

The reply is a new incoming DM: you see it by the chat being open, and the
existing push path notifies when Peel is in the background. No new
notification or Live Activity.

## Permissions
None new. The message is an empty String parameter, so Siri/Shortcuts asks for
it and the system's dictation does the speech. Peel opens no audio engine on
iPhone (the Mac's `Dictation/DictationAudioCapture.swift` is untouched; no overlap).

## Limits
- The intent opens Peel (`supportedModes = .foreground(.immediate)`): the
  account may be PIN/biometric locked and the model lives in the app. While
  locked, the text waits in memory and is sent after unlock; it is never
  written to disk, so quitting Peel drops it. Sending without opening the app
  needs a shared headless send path: future work.
- The device must be unlocked, or be unlocked by the user, for the intent to run.
- Action button: iPhone 15 Pro and later.

## Voice mode
The planned "Peel agent voice mode" will send spoken turns through the same
`AppModel.send(_:from:)`, with a `[voice]` tag decided there. `AgentInbox` is
the one entry for text from outside the UI and can carry `spoken: Bool` later.
Dictated text is ordinary text now. Short, spoken-style replies are an
agent-prompt concern of voice mode, not changed here.

## Risks
Not tested on a physical Action button. Dictation quality is the system's.
Two quick presses queue (no double submit of one text). Siri's
`requestValueDialog` is not shown when a Shortcut supplies the text itself.
