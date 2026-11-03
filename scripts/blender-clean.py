#!/usr/bin/env python3
"""Räumt Photogrammetrie-Meshes in Blender headless auf.

Der Aufruf erfolgt über Blender, nicht über Python:

    blender --background --factory-startup --python scripts/blender-clean.py -- \
        --input scan.glb --output scan-clean.glb --target-tris 60000

Schritte: importieren, Objekte zusammenführen, doppelte Punkte verschmelzen,
lose Punkte und kleine Inseln entfernen, Löcher schließen, Normale nach außen,
dezimieren, Texturen begrenzen, exportieren. Das Ergebnisprotokoll geht als
JSON auf die Standardausgabe oder in eine Datei (`--report`).
"""

from __future__ import annotations

import argparse
import json
import math
import sys
import time
from pathlib import Path
from typing import Any

import bmesh
import bpy

MESH_SUFFIXES = {
    ".glb",
    ".gltf",
    ".obj",
    ".usdz",
    ".usd",
    ".usdc",
    ".usda",
    ".fbx",
    ".stl",
    ".ply",
}
USD_SUFFIXES = {".usdz", ".usd", ".usdc", ".usda"}


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="blender-clean",
        description="Photogrammetrie-Mesh aufräumen und exportieren.",
    )
    parser.add_argument("--input", required=True, help="Quelldatei")
    parser.add_argument("--output", required=True, help="Zieldatei (.glb, .obj, …)")
    parser.add_argument("--report", help="Pfad für das JSON-Protokoll")
    parser.add_argument(
        "--target-tris",
        type=int,
        default=0,
        help="Ziel-Dreieckszahl; 0 lässt die Geometrie unangetastet",
    )
    parser.add_argument(
        "--merge-distance",
        type=float,
        default=0.0001,
        help="Abstand für remove_doubles in Metern; 0 schaltet ab",
    )
    parser.add_argument(
        "--fill-holes",
        action="store_true",
        help="Offene Ränder schließen (Löcher ungesehener Stellen)",
    )
    parser.add_argument(
        "--max-hole-sides",
        type=int,
        default=0,
        help="Nur Löcher bis zu dieser Randlänge füllen; 0 füllt alle",
    )
    parser.add_argument(
        "--keep-largest",
        action="store_true",
        help="Nur die größte zusammenhängende Insel behalten",
    )
    parser.add_argument(
        "--min-island-faces",
        type=int,
        default=0,
        help="Inseln unter dieser Flächenzahl entfernen; 0 schaltet ab",
    )
    parser.add_argument(
        "--up",
        choices=("keep", "Z", "Y"),
        default="keep",
        help="Achse nach oben drehen (Y für USDZ aus ARKit)",
    )
    parser.add_argument(
        "--unit-scale",
        type=float,
        default=1.0,
        help="Skalierungsfaktor vor dem Export",
    )
    parser.add_argument(
        "--smooth-angle",
        type=float,
        default=0.0,
        help="Smooth by Angle in Grad; 0 schaltet ab",
    )
    parser.add_argument(
        "--texture-max",
        type=int,
        default=0,
        help="Texturen auf diese Kantenlänge begrenzen; 0 schaltet ab",
    )
    parser.add_argument(
        "--decimate-mode",
        choices=("collapse", "planar"),
        default="collapse",
        help="Verfahren der Dezimierung",
    )
    parser.add_argument(
        "--quiet", action="store_true", help="Kein Protokoll auf stdout"
    )
    return parser.parse_args(argv)


def blender_args() -> list[str]:
    argv = sys.argv
    if "--" not in argv:
        raise SystemExit("Aufruf über Blender mit '--' vor den Argumenten")
    return argv[argv.index("--") + 1 :]


def reset_scene() -> None:
    bpy.ops.wm.read_factory_settings(use_empty=True)


def import_mesh(path: Path) -> None:
    suffix = path.suffix.lower()
    if suffix not in MESH_SUFFIXES:
        raise SystemExit(f"Nicht unterstütztes Format: {suffix}")
    filepath = str(path)
    if suffix in {".glb", ".gltf"}:
        bpy.ops.import_scene.gltf(filepath=filepath)
    elif suffix == ".obj":
        bpy.ops.wm.obj_import(filepath=filepath)
    elif suffix in USD_SUFFIXES:
        bpy.ops.wm.usd_import(filepath=filepath)
    elif suffix == ".fbx":
        bpy.ops.import_scene.fbx(filepath=filepath)
    elif suffix == ".stl":
        bpy.ops.wm.stl_import(filepath=filepath)
    elif suffix == ".ply":
        bpy.ops.wm.ply_import(filepath=filepath)


def join_meshes() -> Any:
    objects = [o for o in bpy.context.scene.objects if o.type == "MESH"]
    if not objects:
        raise SystemExit("Keine Mesh-Objekte in der Datei gefunden")
    bpy.ops.object.select_all(action="DESELECT")
    for obj in objects:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = objects[0]
    if len(objects) > 1:
        bpy.ops.object.join()
    obj = bpy.context.view_layer.objects.active
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    return obj


def count_tris(mesh: bpy.types.Mesh) -> int:
    return sum(max(len(p.vertices) - 2, 0) for p in mesh.polygons)


def bm_stats(bm: bmesh.types.BMesh) -> dict[str, int]:
    boundary = 0
    non_manifold = 0
    for edge in bm.edges:
        faces = len(edge.link_faces)
        if faces == 1:
            boundary += 1
        elif faces > 2:
            non_manifold += 1
    return {
        "vertices": len(bm.verts),
        "faces": len(bm.faces),
        "tris": sum(max(len(f.verts) - 2, 0) for f in bm.faces),
        "boundary_edges": boundary,
        "non_manifold_edges": non_manifold,
    }


def drop_islands(bm: bmesh.types.BMesh, min_faces: int) -> int:
    """Entfernt kleine zusammenhängende Inseln; gibt die Zahl zurück."""
    if min_faces <= 0:
        return 0
    bm.faces.ensure_lookup_table()
    seen: set[int] = set()
    islands: list[list[int]] = []
    for face in bm.faces:
        if face.index in seen:
            continue
        stack = [face]
        seen.add(face.index)
        component: list[int] = []
        while stack:
            current = stack.pop()
            component.append(current.index)
            for edge in current.edges:
                for neighbour in edge.link_faces:
                    if neighbour.index not in seen:
                        seen.add(neighbour.index)
                        stack.append(neighbour)
        islands.append(component)
    if len(islands) <= 1:
        return 0
    drop_indices = {
        index
        for component in islands
        if len(component) < min_faces
        for index in component
    }
    if not drop_indices:
        return 0
    drop = [bm.faces[i] for i in drop_indices]
    bmesh.ops.delete(bm, geom=drop, context="FACES")
    return len(islands) - sum(1 for component in islands if len(component) >= min_faces)


def keep_largest_island(bm: bmesh.types.BMesh) -> int:
    bm.faces.ensure_lookup_table()
    seen: set[int] = set()
    largest: list[int] = []
    for face in bm.faces:
        if face.index in seen:
            continue
        stack = [face]
        seen.add(face.index)
        component: list[int] = []
        while stack:
            current = stack.pop()
            component.append(current.index)
            for edge in current.edges:
                for neighbour in edge.link_faces:
                    if neighbour.index not in seen:
                        seen.add(neighbour.index)
                        stack.append(neighbour)
        if len(component) > len(largest):
            largest = component
    if not largest or len(largest) == len(bm.faces):
        return 0
    keep = set(largest)
    drop = [bm.faces[i] for i in range(len(bm.faces)) if i not in keep]
    bmesh.ops.delete(bm, geom=drop, context="FACES")
    return 1


def clean_geometry(obj: Any, args: argparse.Namespace) -> dict[str, Any]:
    mesh = obj.data
    bm = bmesh.new()
    bm.from_mesh(mesh)
    before = bm_stats(bm)

    if args.merge_distance > 0:
        bmesh.ops.remove_doubles(bm, verts=bm.verts[:], dist=args.merge_distance)

    loose = [v for v in bm.verts if not v.link_edges]
    if loose:
        bmesh.ops.delete(bm, geom=loose, context="VERTS")

    islands_dropped = 0
    if args.keep_largest:
        islands_dropped = keep_largest_island(bm)
    elif args.min_island_faces > 0:
        islands_dropped = drop_islands(bm, args.min_island_faces)

    holes_filled = 0
    if args.fill_holes:
        boundary = [e for e in bm.edges if len(e.link_faces) == 1]
        if boundary:
            result = bmesh.ops.holes_fill(bm, edges=boundary, sides=args.max_hole_sides)
            holes_filled = len(result.get("faces", []))

    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    after = bm_stats(bm)
    bm.to_mesh(mesh)
    bm.free()
    mesh.update()

    return {
        "before": before,
        "after": after,
        "holes_filled": holes_filled,
        "islands_removed": islands_dropped,
    }


def decimate(obj: Any, args: argparse.Namespace) -> dict[str, Any]:
    before = count_tris(obj.data)
    if args.target_tris <= 0 or before <= args.target_tris:
        return {"tris_before": before, "tris_after": before, "skipped": True}

    modifier = obj.modifiers.new("decimate", "DECIMATE")
    modifier.decimate_type = args.decimate_mode.upper()
    if args.decimate_mode == "collapse":
        modifier.ratio = args.target_tris / before
        modifier.use_collapse_triangulate = True
    else:
        modifier.angle_limit = math.radians(5.0)

    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.modifier_apply(modifier=modifier.name)
    return {
        "tris_before": before,
        "tris_after": count_tris(obj.data),
        "skipped": False,
    }


def limit_textures(max_size: int) -> list[dict[str, Any]]:
    if max_size <= 0:
        return []
    report: list[dict[str, Any]] = []
    for image in bpy.data.images:
        if image.source != "FILE" and image.source != "GENERATED":
            continue
        width, height = image.size
        if max(width, height) <= max_size:
            continue
        factor = max_size / max(width, height)
        new_size = (max(int(width * factor), 1), max(int(height * factor), 1))
        image.scale(new_size[0], new_size[1])
        report.append(
            {"name": image.name, "from": [width, height], "to": list(new_size)}
        )
    return report


def texture_images() -> list[dict[str, Any]]:
    """Every file-backed image in the scene, with its pixel size.

    ``limit_textures`` reports only what it had to shrink, so an empty list
    there does not mean "no texture": it means "nothing needed scaling". This
    inventory answers the question that matters after a conversion.
    """
    images: list[dict[str, Any]] = []
    for image in bpy.data.images:
        if image.source != "FILE":
            continue
        width, height = image.size
        images.append({"name": image.name, "size": [width, height]})
    return images


def orient(obj: Any, args: argparse.Namespace) -> None:
    if args.up == "Y":
        obj.rotation_euler[0] = math.radians(-90.0)
    if args.unit_scale != 1.0:
        obj.scale = (args.unit_scale,) * 3
    if args.up != "keep" or args.unit_scale != 1.0:
        bpy.ops.object.select_all(action="DESELECT")
        obj.select_set(True)
        bpy.context.view_layer.objects.active = obj
        bpy.ops.object.transform_apply(location=False, rotation=True, scale=True)


def shade(obj: Any, args: argparse.Namespace) -> None:
    if args.smooth_angle <= 0:
        return
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.shade_smooth_by_angle(angle=math.radians(args.smooth_angle))


def export(obj: Any, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    suffix = path.suffix.lower()
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    filepath = str(path)
    if suffix in {".glb", ".gltf"}:
        bpy.ops.export_scene.gltf(
            filepath=filepath,
            export_format="GLB" if suffix == ".glb" else "GLTF_SEPARATE",
            use_selection=True,
            export_apply=True,
            export_yup=True,
        )
    elif suffix == ".obj":
        bpy.ops.wm.obj_export(
            filepath=filepath, export_selected_objects=True, export_materials=True
        )
    elif suffix == ".ply":
        bpy.ops.wm.ply_export(filepath=filepath, export_selected_objects=True)
    elif suffix == ".stl":
        bpy.ops.wm.stl_export(filepath=filepath, export_selected_objects=True)
    elif suffix in USD_SUFFIXES:
        bpy.ops.wm.usd_export(filepath=filepath, selected_objects_only=True)
    else:
        raise SystemExit(f"Nicht unterstütztes Exportformat: {suffix}")


def dimensions_mm(obj: Any) -> list[float]:
    return [round(value * 1000.0, 2) for value in obj.dimensions]


def main() -> None:
    args = parse_args(blender_args())
    source = Path(args.input).expanduser().resolve()
    target = Path(args.output).expanduser().resolve()
    if not source.exists():
        raise SystemExit(f"Quelle fehlt: {source}")

    timings: dict[str, float] = {}
    started = time.time()

    reset_scene()
    step = time.time()
    import_mesh(source)
    obj = join_meshes()
    timings["import"] = round(time.time() - step, 2)

    step = time.time()
    cleaned = clean_geometry(obj, args)
    timings["clean"] = round(time.time() - step, 2)

    step = time.time()
    reduced = decimate(obj, args)
    timings["decimate"] = round(time.time() - step, 2)

    step = time.time()
    textures = limit_textures(args.texture_max)
    timings["textures"] = round(time.time() - step, 2)

    step = time.time()
    orient(obj, args)
    shade(obj, args)
    export(obj, target)
    timings["export"] = round(time.time() - step, 2)

    report = {
        "input": str(source),
        "output": str(target),
        "output_bytes": target.stat().st_size if target.exists() else 0,
        "source_bytes": source.stat().st_size,
        "geometry": cleaned,
        "decimate": reduced,
        "textures": textures,
        "texture_images": texture_images(),
        "dimensions_mm": dimensions_mm(obj),
        "objects": len(bpy.context.scene.objects),
        "timings_s": timings,
        "total_s": round(time.time() - started, 2),
    }
    payload = json.dumps(report, indent=2, ensure_ascii=False)
    if args.report:
        Path(args.report).expanduser().write_text(payload + "\n", encoding="utf-8")
    if not args.quiet:
        print("REPORT " + payload)


if __name__ == "__main__":
    main()
