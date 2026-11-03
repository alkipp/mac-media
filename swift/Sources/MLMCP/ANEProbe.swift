// ANEProbe.swift — prüft mit MLComputePlan, welchem Compute-Gerät CoreML
// die Layer eines Modells zuordnet.

import CoreML
import Foundation
import MCP

/// Führt das Modell einmal aus und liest danach den Compute-Plan.
func aneProbe(modelPath: URL) async throws -> String {
    let compiled = try await MLModel.compileModel(at: modelPath)
    let configuration = MLModelConfiguration()
    configuration.computeUnits = .cpuAndNeuralEngine
    let model = try MLModel(contentsOf: compiled, configuration: configuration)

    // Ein Lauf stellt sicher, dass die Layer tatsächlich ausgeführt werden.
    let input = try MLMultiArray(shape: [1, 3, 128, 128], dataType: .float32)
    for index in 0..<input.count {
        input[index] = NSNumber(value: 0.5)
    }
    let provider = try MLDictionaryFeatureProvider(
        dictionary: ["input": MLFeatureValue(multiArray: input)]
    )
    _ = try await model.prediction(from: provider)

    let plan = try await MLComputePlan.load(
        contentsOf: compiled,
        configuration: configuration
    )

    guard case let .neuralNetwork(network) = plan.modelStructure else {
        return "Modell ist kein NeuralNetwork (Compute-Plan nicht ausgewertet)"
    }

    var counts: [String: Int] = [:]
    var lines = ["layers: \(network.layers.count)"]
    for layer in network.layers {
        let usage = plan.deviceUsage(for: layer)
        let device: String
        switch usage?.preferred {
        case .neuralEngine:
            device = "neuralEngine"
        case .gpu:
            device = "gpu"
        case .cpu:
            device = "cpu"
        case nil:
            device = "unbekannt"
        @unknown default:
            device = "unbekannt"
        }
        counts[device, default: 0] += 1
        lines.append("- \(layer.name): \(device)")
    }

    let summary = counts.keys.sorted().map { "\($0)=\(counts[$0]!)" }.joined(separator: ", ")
    lines.append("summary: \(summary)")
    return lines.joined(separator: "\n")
}
