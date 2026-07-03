import AppKit

/// Editable screenshot: base bitmap + vector annotations, with undo/redo
/// snapshots covering both (crop and background-removal replace the base).
final class EditorDocument {
    private(set) var base: CGImage
    private(set) var annotations: [Annotation] = []

    private var undoStack: [(CGImage, [Annotation])] = []
    private var redoStack: [(CGImage, [Annotation])] = []

    var counterValue = 1

    init(base: CGImage) {
        self.base = base
    }

    var pixelSize: CGSize {
        CGSize(width: base.width, height: base.height)
    }

    var flattened: CGImage {
        ImageFlattener.flatten(base: base, annotations: annotations)
    }

    // MARK: - Mutations (each records an undo snapshot)

    func add(_ annotation: Annotation) {
        snapshot()
        annotations.append(annotation)
    }

    func remove(at index: Int) {
        guard annotations.indices.contains(index) else { return }
        snapshot()
        annotations.remove(at: index)
    }

    func beginTranslation() {
        snapshot()
    }

    func translateAnnotation(at index: Int, by delta: CGPoint) {
        guard annotations.indices.contains(index) else { return }
        annotations[index].translate(by: delta)
    }

    func crop(to rect: CGRect) {
        let clamped = rect.integral.intersection(CGRect(x: 0, y: 0, width: base.width, height: base.height))
        guard !clamped.isEmpty, let cropped = base.cropping(to: clamped) else { return }
        snapshot()
        base = cropped
        let delta = CGPoint(x: -clamped.minX, y: -clamped.minY)
        annotations = annotations.map { annotation in
            var moved = annotation
            moved.translate(by: delta)
            return moved
        }
    }

    func replaceBase(with image: CGImage) {
        snapshot()
        base = image
    }

    /// Mutates one annotation (e.g. restyling from the prop bar), undoable.
    func updateAnnotation(at index: Int, _ mutate: (inout Annotation) -> Void) {
        guard annotations.indices.contains(index) else { return }
        snapshot()
        mutate(&annotations[index])
    }

    /// Fresh document state for reusing the editor window with a new capture.
    func reset(base newBase: CGImage) {
        base = newBase
        annotations = []
        undoStack = []
        redoStack = []
        counterValue = 1
    }

    // MARK: - Undo

    private func snapshot() {
        undoStack.append((base, annotations))
        redoStack.removeAll()
        if undoStack.count > 100 {
            undoStack.removeFirst()
        }
    }

    func undo() {
        guard let (image, shapes) = undoStack.popLast() else { return }
        redoStack.append((base, annotations))
        base = image
        annotations = shapes
    }

    func redo() {
        guard let (image, shapes) = redoStack.popLast() else { return }
        undoStack.append((base, annotations))
        base = image
        annotations = shapes
    }
}
