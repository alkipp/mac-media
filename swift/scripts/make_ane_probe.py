#!/usr/bin/env python3
"""Erzeugt ein kleines CoreML-NeuralNetwork-Modell für den ANE-Nachweis.

Aufruf:
    /pfad/zu/python swift/scripts/make_ane_probe.py swift/models/ane_probe.mlmodel

Das Modell hat eine 3×3-Faltung und eine ReLU; es dient nur dazu, mit
`MLComputePlan` zu prüfen, welchem Compute-Gerät CoreML die Layer zuordnet.
"""

import sys
from pathlib import Path

import coremltools as ct
import numpy as np
from coremltools.models import datatypes
from coremltools.models.neural_network import NeuralNetworkBuilder


def main() -> None:
    target = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("ane_probe.mlmodel")
    target.parent.mkdir(parents=True, exist_ok=True)

    inputs = [("input", datatypes.Array(1, 3, 128, 128))]
    outputs = [("output", datatypes.Array(1, 32, 128, 128))]

    builder = NeuralNetworkBuilder(
        inputs, outputs, disable_rank5_shape_mapping=True
    )
    random = np.random.RandomState(0)
    activations = [
        ("conv1", "input", 3, 32, "relu1"),
        ("conv2", "relu1", 32, 32, "relu2"),
        ("conv3", "relu2", 32, 32, "output"),
    ]
    for name, input_name, kernel_channels, output_channels, next_name in activations:
        weights = random.rand(output_channels, kernel_channels, 3, 3).astype(np.float32)
        bias = np.zeros(output_channels, dtype=np.float32)
        builder.add_convolution(
            name=name,
            kernel_channels=kernel_channels,
            output_channels=output_channels,
            height=3,
            width=3,
            stride_height=1,
            stride_width=1,
            border_mode="same",
            groups=1,
            W=weights,
            b=bias,
            has_bias=True,
            input_name=input_name,
            output_name=name + "_out",
        )
        builder.add_activation(
            name=next_name,
            non_linearity="RELU",
            input_name=name + "_out",
            output_name=next_name if next_name == "output" else next_name,
        )

    model = ct.models.MLModel(builder.spec)
    model.save(str(target))

    probe = np.full((1, 3, 128, 128), 0.5, dtype=np.float32)
    result = model.predict({"input": probe})
    print(f"geschrieben: {target} ({target.stat().st_size} Bytes)")
    print("Probe-Ausgabe:", result["output"].shape, float(result["output"].sum()))


if __name__ == "__main__":
    main()
