import SwiftUI

struct CollabRoomView: View {
    @Environment(\.dismiss) private var dismiss

    struct CollabProject: Identifiable {
        let id = UUID()
        let title: String
        let members: [String]
        let progress: Double
        let frames: Int
    }

    let projects: [CollabProject] = [
        CollabProject(title: "Epic Duel Animation", members: ["PixelFury", "NeonBlade", "You"], progress: 0.68, frames: 48),
        CollabProject(title: "Parkour Sequence", members: ["StickMaster", "You"], progress: 0.35, frames: 24),
    ]

    let requests = [
        "Needs animator for fight scene (3 frames left)",
        "Looking for BG artist for nature scene",
        "Need voice actor for 30s clip",
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: { dismiss() }) {
                    Image(systemName: "chevron.left")
                        .foregroundColor(.secondary)
                        .font(.title3)
                }
                Text("🤝 Collab Room")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
            }
            .padding()
            .background(Color(hex: "0A0A14"))

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("ACTIVE PROJECTS")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary)
                        .tracking(2)

                    ForEach(projects) { project in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(project.title)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                            Text(project.members.joined(separator: " · ") + " · \(project.frames) frames")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)

                            ProgressView(value: project.progress)
                                .tint(.red)

                            HStack {
                                Text("\(Int(project.progress * 100))% complete")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                Spacer()
                                Button("Open →") {}
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 5)
                                    .background(Color.red)
                                    .cornerRadius(6)
                            }
                        }
                        .padding()
                        .background(Color.white.opacity(0.04))
                        .cornerRadius(12)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.06)))
                    }

                    Text("LOOKING FOR COLLABS")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary)
                        .tracking(2)
                        .padding(.top, 8)

                    ForEach(requests, id: \.self) { req in
                        HStack {
                            Text(req)
                                .font(.system(size: 11))
                                .foregroundColor(.white)
                            Spacer()
                            Button("Join") {}
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.red)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Color.red.opacity(0.15))
                                .cornerRadius(6)
                        }
                        .padding(12)
                        .background(Color.white.opacity(0.03))
                        .cornerRadius(8)
                    }
                }
                .padding()
            }
        }
        .background(Color(hex: "0A0A14"))
        .navigationBarHidden(true)
    }
}
