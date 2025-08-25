import SwiftUI

struct ChangeUnlockPatternView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var currentInput: [Int] = []

    var body: some View {
        VStack {
            Text("Neues Entsperrmuster")
                .font(.title2)
                .padding(.top)

            Spacer()

            GeometryReader { geo in
                let size = geo.size
                let buttonSize = CGSize(width: size.width / 3, height: size.height / 3)

                VStack(spacing: 0) {
                    ForEach(0..<3) { row in
                        HStack(spacing: 0) {
                            ForEach(0..<3) { col in
                                let index = row * 3 + col
                                Rectangle()
                                    .foregroundStyle(.black)
                                    .frame(width: buttonSize.width, height: buttonSize.height)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        handleTap(index)
                                    }
                                    .overlay(
                                        Text(currentInput.contains(index) ? "●" : "")
                                            .foregroundStyle(.white)
                                            .font(.title)
                                    )
                            }
                        }
                    }
                }
            }

            Spacer()

            Button("Zurücksetzen") {
                currentInput.removeAll()
            }
            .padding(.bottom)

            Button("Speichern") {
                save()
            }
            .disabled(currentInput.count != 4)
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(Color.black)
        .foregroundColor(.white)
        .navigationTitle("Muster ändern")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func handleTap(_ index: Int) {
        guard !currentInput.contains(index), currentInput.count < 4 else { return }
        currentInput.append(index)
    }

    private func save() {
        guard currentInput.count == 4 else { return }
        do {
            try UnlockManager.savePattern(currentInput)
            dismiss()
        } catch {
            print("❌ Muster-Speichern fehlgeschlagen:", error.localizedDescription)
        }
    }
}
