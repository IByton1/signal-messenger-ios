import SwiftUI

struct LaunchUnlockView: View {
    // MARK: – State
    @State private var tapSequence: [Int] = []
    @State private var unlocked = false
    @State private var isLocked = false
    
    // MARK: – Init
    init() {
        UnlockManager.bootstrapIfNeeded()   // legt Default-Muster an, falls nötig
    }
    
    // MARK: – View
    var body: some View {
        if unlocked {
            ContactsListView()
        } else {
            VStack(spacing: 24) {
                Text("SafeChat entsperren")
                    .font(.title.bold())
                
                Text("Tippe dein Muster")
                    .foregroundStyle(.secondary)
                
                // 3×3 Grid
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 20), count: 3), spacing: 20) {
                    ForEach(0..<9, id: \.self) { index in
                        Circle()
                            .fill(tapSequence.contains(index) ? Color.accentColor : Color.gray.opacity(0.3))
                            .frame(width: 80, height: 80)
                            .overlay(
                                Circle()
                                    .stroke(Color.accentColor, lineWidth: tapSequence.contains(index) ? 3 : 1)
                            )
                            .scaleEffect(tapSequence.contains(index) ? 0.9 : 1.0)
                            .animation(.spring(response: 0.3), value: tapSequence)
                            .onTapGesture {
                                handleTap(index: index)
                            }
                            // Long-Press Reset auf Feld 8
                            .simultaneousGesture(
                                index == 8
                                ? LongPressGesture(minimumDuration: 3.0)
                                    .onEnded { _ in resetLock() }
                                : nil
                            )
                    }
                }
                .padding()
                
                if isLocked {
                    Text("🔒 Falsches Muster – gesperrt")
                        .foregroundColor(.red)
                        .font(.headline)
                        .transition(.opacity)
                }
            }
            .padding()
        }
    }
    
    // MARK: – Logik
    private func handleTap(index: Int) {
        guard !isLocked else { return }
        
        tapSequence.append(index)
        
        if tapSequence.count == 4 { // Muster-Länge festgelegt
            if UnlockManager.verify(pattern: tapSequence) {
                unlocked = true
            } else {
                isLocked = true
                print("🔒 Falsches Muster – gesperrt")
            }
        }
    }
    
    private func resetLock() {
        print("🔓 Zurückgesetzt – neue Eingabe möglich")
        tapSequence.removeAll()
        isLocked = false
    }
}
