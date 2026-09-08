import SwiftUI

struct StudioProjectLibrary: View {
    @ObservedObject var vm: StudioViewModel
    @State private var creating = false
    @State private var name = "Untitled Animation"
    @State private var format = 0
    @State private var fps = 12
    private let formats = [("Portrait", 1080, 1920), ("Square", 1080, 1080), ("Landscape", 1920, 1080)]

    var body: some View {
        ZStack {
            Color(hex: "0D0D12").ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Studio").font(.specialElite(28)).foregroundColor(.white)
                            .accessibilityIdentifier("studio.library")
                        Text("YOUR ANIMATIONS · ON THIS DEVICE")
                            .font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundColor(.gray)
                    }
                    Spacer()
                    Button { creating = true } label: {
                        Label("New Project", systemImage: "plus").font(.specialElite(13))
                            .foregroundColor(.white).padding(12).background(Color.red).cornerRadius(12)
                    }.accessibilityIdentifier("studio.new-project")
                }
                if let message = vm.message { Text(message).font(.caption).foregroundColor(.red).accessibilityIdentifier("studio.status") }
                ScrollView {
                    if vm.savedProjects.isEmpty {
                        VStack(spacing: 14) {
                            Image(systemName: "pencil.and.scribble").font(.system(size: 48)).foregroundColor(.red)
                            Text("Your next animation starts here.").font(.specialElite(18)).foregroundColor(.white)
                            Text("Create, draw and save offline. Your projects stay on this device.")
                                .font(.callout).foregroundColor(.gray).multilineTextAlignment(.center)
                        }.frame(maxWidth: .infinity).padding(.vertical, 70)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                        ForEach(vm.savedProjects, id: \.id) { project in
                            Button { Task { await vm.openProject(project) } } label: {
                                VStack(alignment: .leading, spacing: 10) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)).frame(height: 110)
                                        Image(systemName: "film.stack").font(.system(size: 30)).foregroundColor(.red)
                                    }
                                    Text(project.title).font(.specialElite(14)).foregroundColor(.white).lineLimit(2)
                                    Text("\(project.frameCount) frames · \(project.fps) FPS")
                                        .font(.system(size: 10, design: .monospaced)).foregroundColor(.gray)
                                }.padding(12).background(Color(hex: "17171F")).cornerRadius(14)
                            }
                            .accessibilityIdentifier("studio.project.\(project.id.uuidString)")
                            .accessibilityLabel(project.title)
                        }
                    }
                }.refreshable { await vm.loadProjects() }
            }.padding(16)
        }
        .sheet(isPresented: $creating) {
            NavigationStack {
                Form {
                    TextField("Project name", text: $name).accessibilityIdentifier("studio.project-name")
                    Picker("Canvas", selection: $format) {
                        ForEach(formats.indices, id: \.self) { i in Text(formats[i].0).tag(i) }
                    }
                    Picker("Frames per second", selection: $fps) {
                        ForEach([12, 24, 30, 60], id: \.self) { Text("\($0) FPS").tag($0) }
                    }
                    Text("Stored on this device. Cloud publishing and audio/video export are still unfinished.").font(.caption)
                }
                .navigationTitle("New Animation")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { creating = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Create") {
                            let selected = formats[format]
                            Task {
                                _ = await vm.createProject(name: name, width: selected.1, height: selected.2, fps: fps)
                                if vm.isEditing { creating = false }
                            }
                        }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 120)
                        .accessibilityIdentifier("studio.create-project")
                    }
                }
            }.preferredColorScheme(.dark)
        }
    }
}
