import SwiftUI

/// A gold arc chasing itself around a faint ring.
struct LassoSpinner: View {
    var lineWidth: CGFloat = 3

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                Circle()
                    .stroke(Color(nsColor: Palette.shape).opacity(0.18), lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: 0.18 + 0.12 * sin(t * 2.4))
                    .stroke(Color(nsColor: Palette.shape), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(t * 300))
            }
        }
    }
}

/// Shown once per launch while the map draws for the first time.
struct SplashView: View {
    @State private var fact = Int.random(in: 0..<FunFacts.all.count)

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.14, green: 0.26, blue: 0.48), Color(red: 0.04, green: 0.08, blue: 0.19)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 30) {
                ZStack {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 168, height: 168)
                    LassoSpinner(lineWidth: 4)
                        .frame(width: 210, height: 210)
                }

                VStack(spacing: 6) {
                    Text("Populus")
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                    Text("Getting the planet ready…")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 8) {
                    Label("Did you know?", systemImage: "lightbulb.fill")
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(Color(nsColor: Palette.shape))
                    Text(FunFacts.all[fact])
                        .font(.title3)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .id(fact)
                        .transition(.opacity.combined(with: .offset(y: 8)))
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
                .frame(width: 520)
                .frame(minHeight: 120)
                .glassEffect(.regular, in: .rect(cornerRadius: 20))
            }
            .padding(40)
        }
        .environment(\.colorScheme, .dark)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                withAnimation(.easeInOut(duration: 0.6)) { fact = (fact + 1) % FunFacts.all.count }
            }
        }
    }
}

enum FunFacts {
    static let all = [
        "More than half of all people live inside one circle with a radius of about 4,000 km, centred on Southeast Asia. It's called the Valeriepieris circle.",
        "The world passed 8 billion people on 15 November 2022, according to the UN.",
        "India overtook China as the most populous country in 2023.",
        "India and China together are home to more than a third of humanity.",
        "Asia holds about 6 in every 10 people on Earth.",
        "Since around 2007, more people have lived in cities than in the countryside.",
        "Java is the most populous island on Earth, with over 150 million people.",
        "Monaco packs in more than 18,000 people per square kilometre.",
        "Mongolia is the emptiest country, with about 2 people per square kilometre.",
        "Russia is the biggest country by area, yet has fewer than 10 people per square kilometre.",
        "Most Canadians live within about 160 km of the US border.",
        "About 95% of Egyptians live along the Nile, on roughly 5% of the country's land.",
        "Most Australians live within 50 km of the coast.",
        "Greenland is the world's largest island, but only about 56,000 people live there.",
        "Vatican City has fewer than 1,000 residents.",
        "The Pitcairn Islands in the Pacific have only a few dozen residents.",
        "Nigeria has more people than any other country in Africa.",
        "Bangladesh fits over 170 million people into an area only a little bigger than Greece.",
        "This game's city maps count people in squares about 100 m wide.",
        "Tip: Cmd-Shift-D shows the population heatmap after you guess.",
    ]
}
