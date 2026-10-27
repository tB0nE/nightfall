#!/usr/bin/env python3
"""Experimental fixed-shape VDA conversion repair; validate before deployment.

PNNX selects InnerProduct for temporal Linear with a non-unit leading axis.
ncnn InnerProduct flattens 3-D input, unlike torch Linear's last-axis operation.
Keep weights unchanged and explicitly flatten/restore the two spatial/time axes.
Usage: python repair_vda_ncnn_linear.py PREFIX OUTPUT_PREFIX
"""
import argparse
from pathlib import Path
import re
import shutil


def projected_cache(lines):
    """Keep serialized weight order, replace only raw-history processing paths."""
    rows = [line.split() for line in lines[2:]]
    producers = {}
    by_name = {}
    for index, row in enumerate(rows):
        by_name[row[1]] = index
        count = int(row[2])
        for blob in row[4+count:4+count+int(row[3])]:
            producers[blob] = index
    remove, replace, insert = set(), {}, {}
    def producer(blob, kind):
        index = producers[blob]
        if rows[index][0] != kind:
            raise ValueError(f"Expected {kind} for {blob}")
        return index, rows[index]
    for state in range(8):
        qflat_index = by_name[f"temporal_linear_{state*4}_flatten"]
        _, crop = producer(rows[qflat_index][4], "Crop")
        split_index, split = producer(crop[4], "Split")
        add_index, add = producer(split[4], "BinaryOp")
        cat_index, cat = producer(add[4], "Concat")
        add_params = dict(x.split("=", 1) for x in add[7:])
        crop_params = dict(x.split("=", 1) for x in crop[6:])
        if add_params.get("0", "0") != "0" or add_params.get("1", "0") != "0" or crop_params.get("-23309") != "1,31":
            raise ValueError("Current query must use raw state plus position 31")
        if cat[4] != f"in{state+1}" or "0=1" not in cat[7:]:
            raise ValueError("Unexpected raw history concatenation")
        raw, position = cat[5], add[5]
        position_source = position
        visited = set()
        while rows[producers[position_source]][0] == "Split":
            if position_source in visited:
                raise ValueError("Cyclic positional source")
            visited.add(position_source)
            position_source = rows[producers[position_source]][4]
        _, constant = producer(position_source, "MemoryData")
        constant_shape = dict(x.split("=", 1) for x in constant[5:])
        query_layout = dict(x.split("=", 1) for x in rows[by_name[f"temporal_linear_{state*4}_restore"]][6:])
        if constant_shape.get("1") != "32" or constant_shape.get("0") != query_layout["0"] or constant_shape.get("2", "1") != "1":
            raise ValueError("Positional terms must be immutable 32-position model data")
        # Preserve the original public raw-state output fork. Each new consumer
        # receives a Split output so the fixed executor can release inputs safely.
        raw_names = [f"pc_raw_{state}_{i}" for i in range(3)]
        pos_names = [f"pc_pos_{state}_{i}" for i in range(3)]
        insert[cat_index] = " ".join(["Split", f"pc_raw_split_{state}", "1", "3", raw, *raw_names])
        insert[add_index] = " ".join(["Split", f"pc_pos_split_{state}", "1", "3", position, *pos_names])
        crop_index = producers[rows[qflat_index][4]]
        remove.update((cat_index, add_index, split_index, crop_index))
        for role in range(3):
            number = state*4+role
            flatten = by_name[f"temporal_linear_{number}_flatten"]
            remove.add(flatten)
            projection_index, row = producer(f"temporal_linear_{number}_out", "VdaTemporalProjection")
            params = dict(x.split("=", 1) for x in row[6:])
            output_width = int(params["0"])
            if params.get("1") != "0" or int(params["2"]) != output_width**2:
                raise ValueError("Only bias-free square temporal projections can be cached")
            restored = rows[by_name[f"temporal_linear_{number}_restore"]]
            layout = dict(x.split("=", 1) for x in restored[6:])
            params["3"] = layout["2"]
            kind = "VdaPositionedQuery" if role == 0 else "VdaCachedProjection"
            if role:
                params["4"] = str(state)
            replace[projection_index] = " ".join([kind, row[1], "2", "1",
                raw_names[role], pos_names[role], row[5], *[f"{k}={v}" for k, v in params.items()]])
    result = lines[:2]
    removed_blobs = set()
    for index in remove:
        row = rows[index]
        removed_blobs.update(row[4+int(row[2]):4+int(row[2])+int(row[3])])
    for index, row in enumerate(rows):
        if index in insert:
            result.append(insert[index])
        if index in remove or row[0] == "Input" and row[4] != "in0":
            continue
        result.append(replace.get(index, " ".join(row)))
    names = set()
    for line in result[2:]:
        row = line.split()
        names.update(row[4:4+int(row[2])+int(row[3])])
        if set(row[4:4+int(row[2])]) & removed_blobs:
            raise ValueError("Removed raw-history intermediate has an external consumer")
        if any(blob in {f"in{i}" for i in range(1, 9)} for blob in row[4:4+int(row[2])]):
            raise ValueError("Raw history consumer remains in projected graph")
    result[1] = f"{len(result)-2} {len(names)}"
    return result


def fuse_temporal(lines):
    """Replace validated, weight-free attention layout regions; keep projections."""
    restore_rows = {line.split()[1]: line.split() for line in lines[2:]
                    if line.startswith("Reshape temporal_linear_") and "_restore " in line}
    restored = {name: row[5] for name, row in restore_rows.items()}
    output = lines[:2]
    index = 2
    count = 0
    while index < len(lines):
        fields = lines[index].split()
        if fields[0] == "Reshape" and fields[1] == f"temporal_linear_{count*4+2}_restore":
            output.append(lines[index])
            start = index+1
            end = start
            while end < len(lines) and lines[end].split()[1] != f"temporal_linear_{count*4+3}_flatten":
                end += 1
            if end == len(lines):
                raise ValueError("Missing temporal output projection")
            region = [line.split() for line in lines[start:end]]
            if not region or any(row[0] not in {"Reshape", "Permute", "MatMul", "VdaTemporalMatMul", "BinaryOp", "Softmax"} for row in region):
                raise ValueError("Unexpected layers in temporal attention region")
            matmuls = [row for row in region if row[0] in {"MatMul", "VdaTemporalMatMul"}]
            scales = [row for row in region if row[0] == "BinaryOp"]
            softmaxes = [row for row in region if row[0] == "Softmax"]
            if len(matmuls) != 2 or len(scales) != 1 or len(softmaxes) != 1:
                raise ValueError("Temporal attention contract changed")
            mm_params = [dict(x.split("=", 1) for x in row[7:]) for row in matmuls]
            sm_params = dict(x.split("=", 1) for x in softmaxes[0][6:])
            if mm_params[0].get("0", "0") != "1" or mm_params[1].get("0", "0") != "0" or sm_params.get("0") != "2" or sm_params.get("1") != "1":
                raise ValueError("Temporal matrix transpose / softmax axis changed")
            dims = dict(x.split("=", 1) for x in region[0][6:])
            params = dict(x.split("=", 1) for x in scales[0][6:])
            width, heads, tokens = int(dims["0"]), int(dims["1"]), int(dims["2"])
            if params.get("0") != "2" or params.get("1") != "1":
                raise ValueError("Unexpected temporal scale operation")
            scale = float(params["2"])
            if abs(scale-width**-0.5) > 1e-6:
                raise ValueError("Unexpected temporal attention scale")
            q, k, v = [restored[f"temporal_linear_{count*4+i}_restore"] for i in range(3)]
            for i in range(3):
                layout = dict(x.split("=", 1) for x in restore_rows[f"temporal_linear_{count*4+i}_restore"][6:])
                if (int(layout["0"]), int(layout["1"]), int(layout["2"])) != (heads*width, 1 if i==0 else 32, tokens):
                    raise ValueError("Unexpected projected temporal tensor shape")
            produced, consumed = set(), set()
            for row in region:
                inputs, outputs = int(row[2]), int(row[3])
                consumed.update(row[4:4+inputs])
                produced.update(row[4+inputs:4+inputs+outputs])
            destination = region[-1][5]
            if consumed-produced != {q, k, v}:
                raise ValueError("Unexpected external temporal attention inputs")
            for line in lines[end:]:
                row = line.split()
                if (set(row[4:4+int(row[2])]) & produced)-{destination}:
                    raise ValueError("Intermediate temporal tensor is used outside fused region")
            output.append(f"VdaFusedTemporal fused_temporal_{count} 3 1 {q} {k} {v} {destination} "
                          f"0={heads} 1={width} 2={tokens} 3=32 4={scale:.9g}")
            index = end
            count += 1
        else:
            output.append(lines[index])
            index += 1
    if count != 8:
        raise ValueError(f"Expected eight temporal blocks, found {count}")
    names = set()
    for line in output[2:]:
        fields = line.split()
        names.update(fields[4:4+int(fields[2])+int(fields[3])])
    output[1] = f"{len(output)-2} {len(names)}"
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--vulkan-attention", action="store_true",
                        help="Replace CPU-only MatMul with experimental Vulkan layer")
    parser.add_argument("--gemm-projections", action="store_true",
                        help="Use Vulkan Gemm for temporal projections, weights unchanged")
    parser.add_argument("--spatial-attention", action="store_true",
                        help="Use fixed-shape fused spatial self-attention")
    parser.add_argument("--fused-temporal", action="store_true",
                        help="Fuse temporal attention and eliminate head layout temporaries")
    parser.add_argument("--projected-cache", action="store_true",
                        help="Experimental self-fed projected K/V history; sequence mode only")
    args = parser.parse_args()
    shapes = []
    spatial_tokens = []
    for line in Path(str(args.source) + ".pnnx.param").read_text().splitlines():
        fields = line.split()
        if fields and fields[0] == "nn.MultiheadAttention" and args.spatial_attention:
            match = re.search(r"#" + re.escape(fields[4]) + r"=\(1,(\d+),384\)f32", line)
            if not match:
                raise ValueError("Spatial attention requires a known batch-one DINO token shape")
            spatial_tokens.append(int(match[1]))
        if not fields or fields[0] != "nn.Linear":
            continue
        match = re.search(r"#" + re.escape(fields[4]) + r"=\((\d+),(\d+),(\d+)\)f32", line)
        if match and int(match[1]) > 1:
            shapes.append(tuple(map(int, match.groups())))
    lines = Path(str(args.source) + ".ncnn.param").read_text().splitlines()
    if len(shapes) != sum(line.startswith("InnerProduct ") for line in lines):
        raise ValueError("Unexpected conversion: temporal Linear/InnerProduct counts differ")
    if args.spatial_attention and len(spatial_tokens) != sum(line.startswith("MultiHeadAttention ") for line in lines):
        raise ValueError("Spatial attention shapes and converted layers differ")
    result = lines[:2]
    index = 0
    spatial_index = 0
    for line in lines[2:]:
        fields = line.split()
        if fields[0] == "InnerProduct":
            tokens, time, width = shapes[index]
            params = dict(x.split("=", 1) for x in fields[6:])
            output_width = int(params["0"])
            if int(params["2"]) != width * output_width:
                raise ValueError("Temporal Linear weight dimensions differ")
            name = f"temporal_linear_{index}"
            result.append(f"Reshape {name}_flatten 1 1 {fields[4]} {name}_in 0={width} 1={tokens*time}")
            destination = fields[5]
            fields[4:6] = [name + "_in", name + "_out"]
            if args.gemm_projections:
                fields[0] = "VdaTemporalProjection"
                fields.append(f"3={tokens*time}")
            result.append(" ".join(fields))
            result.append(f"Reshape {name}_restore 1 1 {name}_out {destination} 0={output_width} 1={time} 2={tokens}")
            index += 1
        else:
            if args.spatial_attention and fields[0] == "MultiHeadAttention":
                if fields[2:4] != ["1", "1"]:
                    raise ValueError("Only self-attention without masks is supported")
                fields[0] = "VdaSpatialAttention"
                fields.append(f"8={spatial_tokens[spatial_index]}")
                spatial_index += 1
                line = " ".join(fields)
            if args.vulkan_attention and fields[0] == "MatMul":
                fields[0] = "VdaTemporalMatMul"
                line = " ".join(fields)
            result.append(line)
    layers, blobs = map(int, lines[1].split())
    result[1] = f"{layers+2*index} {blobs+2*index}"
    if args.fused_temporal:
        result = fuse_temporal(result)
    if args.projected_cache:
        if not args.gemm_projections:
            raise ValueError("Projected caching requires --gemm-projections")
        result = projected_cache(result)
    Path(str(args.output) + ".ncnn.param").write_text("\n".join(result) + "\n")
    shutil.copyfile(str(args.source) + ".ncnn.bin", str(args.output) + ".ncnn.bin")
    print(f"Repaired {index} temporal Linear operations; weights unchanged")


if __name__ == "__main__":
    main()
