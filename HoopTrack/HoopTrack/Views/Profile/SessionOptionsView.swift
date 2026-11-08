// SessionOptionsView.swift
// Profile → Session options: one switch per helper the shooting session
// offers, each with a line on what it does. All on to start with.

import SwiftUI

struct SessionOptionsView: View {
    @AppStorage(AppPreferences.Key.shotCalls) private var shotCalls = ShotCallMode.voice.rawValue
    @AppStorage(AppPreferences.Key.setupCoach) private var setupCoach = true
    @AppStorage(AppPreferences.Key.drillGuidance) private var drillGuidance = true
    @AppStorage(AppPreferences.Key.timedDrillsWaitForShot) private var timedDrillsWait = true
    @AppStorage(AppPreferences.Key.autoPause) private var autoPause = true
    @AppStorage(AppPreferences.Key.dimDuringSessions) private var dimScreen = true
    @AppStorage(AppPreferences.Key.showTarget) private var showTarget = true
    @AppStorage(AppPreferences.Key.reviewOnVideo) private var reviewOnVideo = true
    @AppStorage(AppPreferences.Key.goAgain) private var goAgain = true

    private var mode: ShotCallMode { ShotCallMode(rawValue: shotCalls) ?? .voice }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Call each shot")
                    Picker("Call each shot", selection: $shotCalls) {
                        ForEach(ShotCallMode.allCases) { Text($0.displayName).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    caption(callsCaption)
                }
                .padding(.vertical, 4)
                option("Setup tips", isOn: $setupCoach,
                       "Before you start, says if the phone's too close, too far or aimed wrong, and when it's in a good spot.")
                option("Drill guidance", isOn: $drillGuidance,
                       "In Around the arc, Mid-side-mid and Free throws, shows which spot or set you're on and when to move.")
                option("Timed drills wait for your first shot", isOn: $timedDrillsWait,
                       "The clock starts when you shoot, not while you walk from the phone to the court.")
                option("Pause when nobody's shooting", isOn: $autoPause,
                       "Two minutes without a shot pauses the clock and the video; your next shot carries on. After 15 minutes it asks if you're done.")
                option("Dim the screen", isOn: $dimScreen,
                       "Turns the screen right down after 20 seconds without a touch, to save battery. Tap to brighten it.")
                option("Show your best", isOn: $showTarget,
                       "Your best in the drill, or your shooting goal, under the score.")
            } header: {
                Text("During a session")
            }
            .listRowBackground(Color.panel)

            Section {
                option("Check flagged shots on video", isOn: $reviewOnVideo,
                       "Watch each call the tracker wasn't sure about, then tap Make or Miss.")
                option("Go again", isOn: $goAgain,
                       "A button on the summary that starts the same session again.")
            } header: {
                Text("After a session")
            }
            .listRowBackground(Color.panel)
        }
        .courtList()
        .navigationTitle("Session options")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var callsCaption: String {
        switch mode {
        case .voice:  return "Says “Make, 7 for 10” after every shot, so you don't need to see the screen. Tips and drill steps are spoken too."
        case .sounds: return "A swish for a make and a clank for a miss. A chime for tips and drill steps."
        case .off:    return "Silent. The screen still shows every call."
        }
    }

    private func option(_ title: String, isOn: Binding<Bool>, _ detail: String) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                caption(detail)
            }
        }
        .padding(.vertical, 2)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
