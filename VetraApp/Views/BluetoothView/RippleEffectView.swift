//
//  RippleEffectView.swift
//  VetraApp
//
//  Graceful ripple animation engine.
//  - When `isActive` is true: spawns waves at a fixed cadence (no repeatForever).
//  - When `isActive` is false: stops spawning immediately; existing waves finish;
//    when the last wave fades, we transition to the idle badge.
//  Notes:
//  - Uses a small timer "engine" to advance time and prune finished waves.
//  - iOS 17+ `.onChange(of:)` two-parameter form.
//  - Provides an explicit initializer so calling `RippleEffectView(isActive: true)` is always valid.
//

import SwiftUI

// MARK: - RippleEffectView

struct RippleEffectView: View {

    /// External driver (e.g., scanning vs discovered).
    var isActive: Bool

    /// Optional callback once we fully leave ripple mode (after last wave disappears).
    var onDeactivated: (() -> Void)?

    // Explicit init to avoid “call takes no arguments” when the synthesized memberwise
    // initializer is not visible due to @State members, access levels, or build quirks.
    init(isActive: Bool = true, onDeactivated: (() -> Void)? = nil) {
        self.isActive = isActive
        self.onDeactivated = onDeactivated
    }

    // MARK: Engine Tunables
    private let rippleDuration: TimeInterval = 2.5   // how long each wave lives
    private let spawnStagger: TimeInterval   = 1.0   // cadence between wave spawns
    private let maxOverlappingWaves: Int     = 2     // keep the layered look

    // MARK: Engine State
    @State private var showRipple: Bool = true
    @State private var waves: [Wave] = []
    @State private var now: Date = Date()
    @State private var lastSpawn: Date = .distantPast
    @State private var hasNotifiedDeactivated = false

    private let ticker = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    // MARK: Body

    var body: some View {
        ZStack {
            if showRipple {
                // Ripple Mode
                ZStack {
                    ForEach(waves) { wave in
                        WaveCircle(progress: progress(for: wave, at: now))
                    }

                    // Center mark
                    Image(systemName: "flame.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 100, height: 100)
                        .opacity(0.5)
                }
                .onReceive(ticker) { time in
                    tick(time)
                }
                .transition(.opacity)
            } else {
                // Idle Mode
                IdleBadgeView()
                    .transition(.opacity)
            }
        }
        .frame(width: 200, height: 200)
        .onAppear {
            // Enter with either ripple or idle depending on isActive
            showRipple = isActive
            if isActive {
                bootstrapIfNeeded()
            } else {
                // Ensure we start idle with no waves
                waves.removeAll()
                hasNotifiedDeactivated = false
            }
        }
        .onChange(of: isActive) { _, newValue in
            handleActivationChange(newValue)
        }
        .accessibilityHidden(true)
    }

    // MARK: - Engine

    private func tick(_ time: Date) {
        now = time

        guard showRipple else { return }

        // 1) Prune finished waves (progress >= 1)
        let beforeCount = waves.count
        waves.removeAll { w in progress(for: w, at: now) >= 1.0 }
        let afterCount = waves.count

        // 2) If deactivating and just ran out of waves, flip to idle
        if !isActive, afterCount == 0, beforeCount > 0 {
            withTransaction(.init(animation: .easeOut(duration: 0.2))) {
                showRipple = false
            }
            if !hasNotifiedDeactivated {
                hasNotifiedDeactivated = true
                onDeactivated?()
            }
            return
        }

        // 3) Spawn a new wave only when active and under the cap
        guard isActive else { return }
        let canSpawn = waves.count < maxOverlappingWaves
        let due = now.timeIntervalSince(lastSpawn) >= spawnStagger
        if canSpawn && due {
            spawnWave(at: now)
        }
    }

    private func progress(for wave: Wave, at time: Date) -> CGFloat {
        let elapsed = time.timeIntervalSince(wave.launchDate)
        let p = max(0.0, min(1.0, elapsed / rippleDuration))
        return CGFloat(p)
    }

    private func spawnWave(at time: Date) {
        waves.append(Wave(launchDate: time))
        lastSpawn = time
    }

    private func bootstrapIfNeeded() {
        // Seed at least one wave instantly so we don't show an empty ring
        if waves.isEmpty {
            let t = Date()
            spawnWave(at: t)
            // Optional: preload a second wave slightly offset for immediate layering
            if maxOverlappingWaves > 1 {
                spawnWave(at: t.addingTimeInterval(spawnStagger))
            }
        }
        hasNotifiedDeactivated = false
    }

    private func handleActivationChange(_ nowActive: Bool) {
        if nowActive {
            // Resume ripple immediately; clear any stale idle state and (re)bootstrap waves.
            withTransaction(.init(animation: .easeIn(duration: 0.15))) {
                showRipple = true
            }
            bootstrapIfNeeded()
        } else {
            // Begin graceful shutdown: stop spawning; let current waves fade out.
            hasNotifiedDeactivated = false
            // If there are zero waves (edge case), jump to idle immediately.
            if waves.isEmpty {
                withTransaction(.init(animation: .easeOut(duration: 0.2))) {
                    showRipple = false
                }
                if !hasNotifiedDeactivated {
                    hasNotifiedDeactivated = true
                    onDeactivated?()
                }
            }
        }
    }
}

// MARK: - Wave Model & Drawing

private struct Wave: Identifiable, Equatable {
    let id = UUID()
    let launchDate: Date
}

private struct WaveCircle: View {
    let progress: CGFloat // 0...1

    // Visual mapping
    private let minScale: CGFloat = 1.0
    private let maxScale: CGFloat = 2.2
    private let maxLineWidth: CGFloat = 8.0
    private let minLineWidth: CGFloat = 0.5

    private var currentScale: CGFloat {
        minScale + (maxScale - minScale) * progress
    }

    private var currentLineWidth: CGFloat {
        max(minLineWidth, maxLineWidth - (maxLineWidth - minLineWidth) * progress)
    }

    private var currentOpacity: Double {
        Double(1.0 - progress)
    }

    var body: some View {
        Circle()
            .stroke(Color.white.opacity(0.30), lineWidth: currentLineWidth)
            .frame(width: 150, height: 150)
            .scaleEffect(currentScale)
            .opacity(currentOpacity)
            // No implicit animation: the engine drives progress.
    }
}

// MARK: - Idle (Non-ripple) State (your provided version)

private struct IdleBadgeView: View {
    @State private var breathe = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.4), lineWidth: 4)
                .frame(width: 160, height: 160)
                .scaleEffect(breathe ? 1.05 : 0.95)
                .animation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true), value: breathe)

            Image(systemName: "flame.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 100, height: 100)
                .opacity(0.6)
        }
        .onAppear { breathe = true } // remove for fully static idle
        .accessibilityHidden(true)
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 40) {
        ZStack {
            Color.teal.ignoresSafeArea()
            RippleEffectView(isActive: true)
        }
        .frame(height: 260)

        ZStack {
            Color.teal.ignoresSafeArea()
            RippleEffectView(isActive: false)
        }
        .frame(height: 260)
    }
}
