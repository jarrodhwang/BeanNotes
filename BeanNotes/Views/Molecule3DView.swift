import Metal
import RealityKit
import SwiftUI

enum MoleculeDisplayStyle: String, CaseIterable, Identifiable {
    case ballAndStick = "Ball & stick"
    case spaceFilling = "Space filling"
    var id: String { rawValue }
}

private enum MoleculeGraphics {
    static let isAvailable = MTLCreateSystemDefaultDevice() != nil
}

struct Molecule3DView: View {
    let example: ChemicalExample
    @Environment(\.scenePhase) private var scenePhase
    @State private var style: MoleculeDisplayStyle = .ballAndStick
    @State private var showsHydrogens = true
    @State private var selectedAtom: Int?
    @State private var resetToken = 0
    @State private var rotation = 0
    @State private var zoom: Float = 1

    private var visibleAtoms: [ChemicalExample.Atom] { example.atoms.filter { showsHydrogens || $0.element != "H" } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(example.name).font(.title3.bold())
                Spacer()
                Text(example.formattedFormula).font(.title3.monospaced())
            }
            Picker("Molecule display", selection: $style) {
                ForEach(MoleculeDisplayStyle.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            ZStack(alignment: .bottomLeading) {
                if scenePhase == .active, MoleculeGraphics.isAvailable {
                    NativeMoleculeView(example: example, style: style, showsHydrogens: showsHydrogens,
                                       resetToken: resetToken, rotation: rotation, zoom: zoom, selectedAtom: $selectedAtom)
                        .accessibilityLabel("3D model of \(example.name)")
                        .accessibilityHint("Drag to rotate and pinch to zoom. Atom inspection and view controls are below.")
                        .accessibilityIdentifier("chemistry.model3D")
                } else {
                    ContentUnavailableView("3D preview paused", systemImage: "cube", description: Text("A supported graphics device and an active app are needed to show this model."))
                }
                if let atom = example.atoms.first(where: { $0.id == selectedAtom }) {
                    Text("\(MoleculeAppearance.name(atom.element)) (\(atom.element)) · atom \(atom.id)")
                        .font(.subheadline.weight(.medium)).padding(10)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)).padding(12)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 340)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            HStack {
                Toggle("Hydrogens", isOn: $showsHydrogens).fixedSize()
                    .accessibilityIdentifier("chemistry.hydrogens")
                Spacer()
                Button("Reset view", systemImage: "arrow.counterclockwise") { resetToken += 1; zoom = 1; rotation = 0 }
                    .accessibilityIdentifier("chemistry.reset3D")
            }
            ViewThatFits(in: .horizontal) {
                HStack { inspectionControls }
                VStack(alignment: .leading) { inspectionControls }
            }
            Text("Drag to rotate · Pinch to zoom · Tap an atom to inspect")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 14) {
                ForEach(Set(visibleAtoms.map(\.element)).sorted(), id: \.self) { element in
                    Label {
                        Text("\(element) · \(MoleculeAppearance.name(element))")
                    } icon: {
                        Circle().fill(Color(uiColor: MoleculeAppearance.color(element)))
                            .overlay(Circle().stroke(.gray.opacity(0.5))).frame(width: 12, height: 12)
                    }.font(.caption)
                }
            }
            Text(example.detail).font(.subheadline)
            Text("Computed example geometry, not a measurement or simulation. Molecules can adopt other shapes. Atom sizes are approximate; colors identify elements.")
                .font(.caption).foregroundStyle(.secondary)
            Link("Source: PubChem · CID \(example.cid)", destination: example.sourceURL).font(.caption)
        }
        .onChange(of: showsHydrogens) { _, _ in selectedAtom = nil }
    }

    @ViewBuilder private var inspectionControls: some View {
        Menu("Inspect atom", systemImage: "scope") {
            ForEach(visibleAtoms) { atom in
                Button("\(MoleculeAppearance.name(atom.element)) · atom \(atom.id)") { selectedAtom = atom.id }
            }
        }
        Button("Rotate", systemImage: "rotate.3d") { rotation += 1 }
        Button("Zoom out", systemImage: "minus.magnifyingglass") { zoom = max(0.65, zoom / 1.2) }
        Button("Zoom in", systemImage: "plus.magnifyingglass") { zoom = min(2.5, zoom * 1.2) }
    }
}

private enum MoleculeAppearance {
    static func color(_ element: String) -> UIColor {
        switch element {
        case "H": UIColor(white: 0.94, alpha: 1)
        case "C": UIColor(red: 0.25, green: 0.29, blue: 0.34, alpha: 1)
        case "N": UIColor(red: 0.2, green: 0.4, blue: 0.95, alpha: 1)
        case "O": UIColor(red: 0.95, green: 0.18, blue: 0.22, alpha: 1)
        default: .systemGreen
        }
    }
    static func name(_ element: String) -> String {
        switch element { case "H": "Hydrogen"; case "C": "Carbon"; case "N": "Nitrogen"; case "O": "Oxygen"; default: element }
    }
    static func radius(_ element: String, style: MoleculeDisplayStyle) -> Float {
        // Conventional approximate van der Waals radii in angstroms (Bondi).
        let radius: Float = switch element { case "H": 1.2; case "C": 1.7; case "N": 1.55; case "O": 1.52; default: 1.7 }
        return style == .spaceFilling ? radius : radius * 0.22
    }
}

/// RealityKit uses the native Metal renderer. One shared sphere/cylinder mesh,
/// a small material palette, no physics, no camera capture and no animation loop.
private struct NativeMoleculeView: UIViewRepresentable {
    let example: ChemicalExample
    let style: MoleculeDisplayStyle
    let showsHydrogens: Bool
    let resetToken: Int
    let rotation: Int
    let zoom: Float
    @Binding var selectedAtom: Int?

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selectedAtom) }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        view.environment.background = .color(UIColor(red: 0.91, green: 0.94, blue: 0.96, alpha: 1))
        view.renderOptions = [.disableMotionBlur, .disableDepthOfField, .disableCameraGrain, .disableGroundingShadows, .disableAREnvironmentLighting]
        context.coordinator.install(in: view)
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {
        context.coordinator.selection = $selectedAtom
        context.coordinator.update(self)
    }

    static func dismantleUIView(_ view: ARView, coordinator: Coordinator) {
        view.scene.anchors.removeAll()
        view.gestureRecognizers?.forEach { view.removeGestureRecognizer($0) }
        coordinator.view = nil
    }

    @MainActor final class Coordinator: NSObject {
        weak var view: ARView?
        var selection: Binding<Int?>
        private let anchor = AnchorEntity(world: .zero)
        private let molecule = Entity()
        private let camera = PerspectiveCamera()
        private let sphere = MeshResource.generateSphere(radius: 1)
        private let cylinder = makeCylinderMesh()
        private var key = ""
        private var resetToken = 0
        private var rotation = 0
        private var buttonZoom: Float = 1
        private var pinchZoom: Float = 1
        private var distance: Float = 12
        private var yaw: Float = 0.3
        private var pitch: Float = -0.2

        init(selection: Binding<Int?>) { self.selection = selection }

        /// Cylinder generation was added to RealityKit in iOS 18. A small shared
        /// mesh keeps the same renderer on BeanNotes' iPadOS 17 minimum target.
        private static func makeCylinderMesh() -> MeshResource {
            var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], indices: [UInt32] = []
            let segments = 16
            for index in 0..<segments {
                let angle = Float(index) * 2 * .pi / Float(segments)
                let normal = SIMD3<Float>(cos(angle), 0, sin(angle))
                positions.append([normal.x, -0.5, normal.z]); positions.append([normal.x, 0.5, normal.z])
                normals.append(normal); normals.append(normal)
                let bottom = UInt32(index * 2), next = UInt32((index + 1) % segments * 2)
                indices.append(contentsOf: [bottom, bottom + 1, next, next, bottom + 1, next + 1])
            }
            var descriptor = MeshDescriptor(name: "Molecular bond")
            descriptor.positions = MeshBuffers.Positions(positions)
            descriptor.normals = MeshBuffers.Normals(normals)
            descriptor.primitives = .triangles(indices)
            return (try? MeshResource.generate(from: [descriptor])) ?? .generateBox(size: 1)
        }

        func install(in view: ARView) {
            self.view = view
            camera.camera = PerspectiveCameraComponent(near: 0.01, far: 200, fieldOfViewInDegrees: 40)
            anchor.addChild(camera)
            anchor.addChild(molecule)
            let keyLight = DirectionalLight()
            keyLight.light.intensity = 2400
            keyLight.look(at: .zero, from: [3, 4, 6], relativeTo: nil)
            anchor.addChild(keyLight)
            let fillLight = DirectionalLight()
            fillLight.light.intensity = 900
            fillLight.look(at: .zero, from: [-3, -1, 2], relativeTo: nil)
            anchor.addChild(fillLight)
            view.scene.addAnchor(anchor)
            let pan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
            pan.maximumNumberOfTouches = 1
            view.addGestureRecognizer(pan)
            view.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:))))
            view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tap(_:))))
        }

        func update(_ configuration: NativeMoleculeView) {
            let newKey = "\(configuration.example.id)-\(configuration.style.rawValue)-\(configuration.showsHydrogens)"
            if key != newKey {
                rebuild(configuration)
                key = newKey
            }
            if resetToken != configuration.resetToken {
                yaw = 0.3; pitch = -0.2; pinchZoom = 1
                resetToken = configuration.resetToken
                rotation = configuration.rotation
            }
            if rotation != configuration.rotation {
                yaw += Float(configuration.rotation - rotation) * .pi / 6
                rotation = configuration.rotation
            }
            buttonZoom = configuration.zoom
            updateCamera()
        }

        private func rebuild(_ configuration: NativeMoleculeView) {
            molecule.children.removeAll()
            let example = configuration.example
            guard example.isValid else { return }
            let center = example.atoms.reduce(SIMD3<Float>.zero) { $0 + $1.position } / Float(example.atoms.count)
            let atoms = example.atoms.filter { configuration.showsHydrogens || $0.element != "H" }
            let indexed = Dictionary(uniqueKeysWithValues: atoms.map { ($0.id, $0) })
            let materials = Dictionary(uniqueKeysWithValues: Set(atoms.map(\.element)).map {
                ($0, SimpleMaterial(color: MoleculeAppearance.color($0), roughness: 0.55, isMetallic: false))
            })
            for atom in atoms {
                guard let material = materials[atom.element] else { continue }
                let radius = MoleculeAppearance.radius(atom.element, style: configuration.style)
                let entity = ModelEntity(mesh: sphere, materials: [material])
                entity.name = "atom-\(atom.id)"
                entity.position = atom.position - center
                entity.scale = SIMD3(repeating: radius)
                entity.collision = CollisionComponent(shapes: [.generateSphere(radius: 1)])
                molecule.addChild(entity)
            }
            if configuration.style == .ballAndStick {
                for bond in example.bonds {
                    guard let first = indexed[bond.start], let second = indexed[bond.end],
                          let materialA = materials[first.element], let materialB = materials[second.element] else { continue }
                    let a = first.position - center, b = second.position - center
                    let vector = b - a
                    guard simd_length(vector) > 0.001 else { continue }
                    let direction = simd_normalize(vector)
                    let basis: SIMD3<Float> = abs(direction.z) < 0.9 ? [0, 0, 1] : [0, 1, 0]
                    let side = simd_normalize(simd_cross(direction, basis))
                    for index in 0..<bond.order {
                        let offset = side * (Float(index) - Float(bond.order - 1) / 2) * 0.18
                        let mid = (a + b) / 2 + offset
                        addBond(from: a + offset, to: mid, material: materialA)
                        addBond(from: mid, to: b + offset, material: materialB)
                    }
                }
            }
            // Fit a bounding sphere, including space-filling radii. The 3D panel is
            // landscape in the sheet, so the vertical field of view is limiting.
            let radius = example.atoms.map { simd_length($0.position - center) + MoleculeAppearance.radius($0.element, style: configuration.style) }.max() ?? 2
            distance = max(5, radius / sin(20 * .pi / 180) * 1.15)
        }

        private func addBond(from start: SIMD3<Float>, to end: SIMD3<Float>, material: SimpleMaterial) {
            let vector = end - start
            let entity = ModelEntity(mesh: cylinder, materials: [material])
            entity.position = (start + end) / 2
            entity.scale = [0.075, simd_length(vector), 0.075]
            entity.orientation = simd_quatf(from: [0, 1, 0], to: simd_normalize(vector))
            molecule.addChild(entity)
        }

        private func updateCamera() {
            molecule.orientation = simd_quatf(angle: yaw, axis: [0, 1, 0]) * simd_quatf(angle: pitch, axis: [1, 0, 0])
            camera.look(at: .zero, from: [0, 0, distance / min(3, max(0.6, buttonZoom * pinchZoom))], relativeTo: nil)
        }

        @objc private func pan(_ gesture: UIPanGestureRecognizer) {
            let delta = gesture.translation(in: view)
            yaw += Float(delta.x) * 0.01
            pitch = min(.pi / 2, max(-.pi / 2, pitch + Float(delta.y) * 0.01))
            gesture.setTranslation(.zero, in: view)
            updateCamera()
        }

        @objc private func pinch(_ gesture: UIPinchGestureRecognizer) {
            pinchZoom = min(3, max(0.6, pinchZoom * Float(gesture.scale)))
            gesture.scale = 1
            updateCamera()
        }

        @objc private func tap(_ gesture: UITapGestureRecognizer) {
            guard let view else { return }
            let name = view.entity(at: gesture.location(in: view))?.name ?? ""
            selection.wrappedValue = name.hasPrefix("atom-") ? Int(name.dropFirst(5)) : nil
        }
    }
}
