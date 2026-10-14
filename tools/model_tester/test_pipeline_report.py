import unittest
import tempfile
import re
from pathlib import Path

import numpy as np
from pipeline_report import Renderer, desktop, shader, unpack, working_size, write_html
from build_contour_inspection import contour_measure


class PipelineTests(unittest.TestCase):
    def test_headset_refinement_matches_comparison_shaders(self):
        renderer = Renderer()
        header = (Path(__file__).resolve().parents[2]/"extensions/nightfall-xr/include/depth_refinement_shaders.h").read_text()
        sources = re.findall(r'R"NFGLSL\((.*?)\)NFGLSL"', header, re.S)
        self.assertEqual(len(sources),2)
        for name, source in zip(("production_align","production_cleanup"),sources):
            renderer.programs[name] = renderer.ctx.program(vertex_shader=desktop(shader("VERTEX_SRC")),fragment_shader=desktop(source))
        depth = np.full((48,64),30,np.uint8)
        colour = np.zeros((96,128,3),np.uint8)
        for y in range(48):
            depth[y,24+y//5+(y%2):] = 220
        for y in range(96):
            colour[y,46+y//5:] = 255
        d, c = renderer.texture(depth),renderer.texture(colour)
        uniforms = {"u_radius":2.,"u_strength":.75}
        expected, pixels = renderer.draw("edge_align",(128,96),{"u_depth":d,"u_guide":c},uniforms)
        got, actual = renderer.draw("production_align",(128,96),{"u_depth":d,"u_guide":c},uniforms)
        np.testing.assert_array_equal(actual,pixels)
        a, pixels = renderer.draw("contour_cleanup",(128,96),{"u_depth":expected},{},dtype="f2")
        b, actual = renderer.draw("production_cleanup",(128,96),{"u_depth":got},{},dtype="f2")
        np.testing.assert_array_equal(actual,pixels)
        for texture in (d,c,expected,got,a,b): texture.release()

    def test_contour_measurement_known_straight_edge(self):
        from PIL import Image
        raw = np.zeros((32,64,3),np.uint8)
        raw[:,24:] = 255
        positions, measured = contour_measure(Image.fromarray(raw),(16,4,32,28))
        np.testing.assert_array_equal(positions,23.5)
        self.assertLess(measured["curve_residual_px"],1e-10)
        with self.assertRaises(ValueError):
            contour_measure(Image.fromarray(np.zeros_like(raw)),(16,4,32,28))

    def test_report_omits_retired_variant_images(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root/"original.png").write_bytes(b"original")
            for name in ("0-bounded-2","0-bounded-3","0-bounded-1"):
                (root/name).mkdir()
                (root/name/"depth.png").write_bytes(b"test")
            write_html(root,{"models":[{"directory":"0-bounded-2"},{"directory":"0-bounded-3"}]})
            html = (root/"index.html").read_text()
            self.assertNotIn("0-bounded-1",html)
            self.assertIn("0-bounded-3/depth.png",html)

    def test_working_grid_floor(self):
        self.assertEqual(working_size((1920,1080),(320,180)),(480,270))
        self.assertEqual(working_size((1920,1080),(512,288)),(512,288))
        self.assertEqual(working_size((1920,1080),(384,384)),(480,270))
        self.assertEqual(working_size((1920,1080),(256,256)),(480,270))
        self.assertEqual(working_size((3840,2160),(512,288)),(960,540))
    def test_pixel_shuffle(self):
        actual = unpack(np.array([[[[1,2,3,4],[5,6,7,8]]]]), "packed2x2")
        np.testing.assert_array_equal(actual, [[1,2,5,6],[3,4,7,8]])

    def test_invalid_packed_output(self):
        with self.assertRaises(ValueError):
            unpack(np.zeros((1,2,2,1)), "packed2x2")

    def test_shader_extraction(self):
        for name in ("VERTEX_SRC", "UPSAMPLE_FRAGMENT_SRC", "OFFSET_FRAGMENT_SRC", "FRAGMENT_SRC"):
            self.assertIn("void main()", shader(name))
            self.assertIn("#version 430 core", desktop(shader(name)))

    def test_capture_orientation_and_neutral_warp(self):
        renderer = Renderer()
        rgb = np.zeros((32,64,3), np.uint8)
        rgb[:16,:,0] = 255
        rgb[16:,:,2] = 255
        source = renderer.texture(rgb)
        captured, pixels = renderer.draw("capture", (64,32), {"u_video":source}, {})
        self.assertGreater(pixels[0,0,0], 250)
        self.assertGreater(pixels[-1,0,2], 250)
        depth = renderer.texture(np.full((32,64),128,np.uint8))
        final, pixels = renderer.draw("FRAGMENT_SRC", (64,32), {"u_texture":source,"u_depth":depth,"u_offsets":depth}, {"u_disparity":0.,"u_occlusion":0.,"u_eyeIndex":0.,"u_convergence":.5,"u_depthProcessStage":1,"u_stereoMode":0})
        np.testing.assert_array_equal(pixels[:,:,:3],rgb)
        for tex in (source,captured,depth,final):
            tex.release()

    def test_linear_pixel_centres(self):
        renderer = Renderer()
        ramp = np.tile(np.arange(64,dtype=np.uint8)*4,(32,1))
        depth = renderer.texture(ramp)
        output, pixels = renderer.draw("UPSAMPLE_FRAGMENT_SRC", (256,128), {"u_depth":depth}, {"u_linear":1})
        # GL normalized UVs map to source texel centres, not align_corners.
        x = np.clip((np.arange(256)+.5)*64/256-.5,0,63)
        np.testing.assert_allclose(pixels[64,:,0], x*4, atol=1)
        depth.release()
        output.release()
        # Non-integer scaling in BOTH axes catches aspect/corner convention
        # errors that a same-size texture or horizontal-only ramp would miss.
        y, x = np.mgrid[:32,:64]
        depth = renderer.texture((x*2+y*4).astype(np.uint8))
        output, pixels = renderer.draw("UPSAMPLE_FRAGMENT_SRC", (237,113), {"u_depth":depth}, {"u_linear":1})
        x = np.clip((np.arange(237)+.5)*64/237-.5,0,63)
        y = np.clip((np.arange(113)+.5)*32/113-.5,0,31)
        np.testing.assert_allclose(pixels[:,:,0], x[None,:]*2+y[:,None]*4, atol=1)
        depth.release()
        output.release()

    def test_bounded_alignment_and_flat_depth(self):
        renderer = Renderer()
        guide = np.zeros((128,256,3), np.uint8)
        guide[:,128:] = 255
        source = renderer.texture(guide)
        raw = np.zeros((32,64), np.uint8)
        raw[:,33:] = 255 # One native texel to the right of the colour edge.
        depth = renderer.texture(raw)
        baseline, before = renderer.draw("UPSAMPLE_FRAGMENT_SRC", (256,128), {"u_depth":depth}, {"u_linear":1})
        aligned, after = renderer.draw("edge_align", (256,128), {"u_depth":depth,"u_guide":source}, {"u_radius":2.,"u_strength":.75})
        def edge_position(pixels):
            row = pixels[64,:,0].astype(float)
            weights = np.abs(np.diff(row))
            return float(np.dot(np.arange(255)+.5,weights)/weights.sum())
        self.assertLess(abs(edge_position(after)-127.5),abs(edge_position(before)-127.5))
        self.assertLessEqual(abs(edge_position(after)-edge_position(before)),8.)
        # High-contrast colour text/edges cannot introduce depth on a flat map.
        flat = renderer.texture(np.full((32,64),128,np.uint8))
        result, pixels = renderer.draw("edge_align", (256,128), {"u_depth":flat,"u_guide":source}, {"u_radius":2.,"u_strength":.75})
        np.testing.assert_array_equal(pixels[:,:,0],128)
        # No colour boundary -> no correction to the baseline depth.
        blank = renderer.texture(np.full((128,256,3),128,np.uint8))
        unchanged, pixels = renderer.draw("edge_align", (256,128), {"u_depth":depth,"u_guide":blank}, {"u_radius":2.,"u_strength":.75})
        np.testing.assert_array_equal(pixels[:,:,0],before[:,:,0])
        for texture in (source,depth,baseline,aligned,flat,result,blank,unchanged):
            texture.release()

    def test_bounded3_preserves_signed_field_and_flat_depth(self):
        renderer = Renderer()
        guide = np.zeros((128,256,3),np.uint8)
        guide[:,64:192] = 255
        raw = np.zeros((32,64),np.uint8)
        raw[:,17:47] = 255
        source, depth = renderer.texture(guide), renderer.texture(raw)
        field, _ = renderer.draw("edge_field", (256,128), {"u_depth":depth,"u_guide":source}, {"u_radius":2.,"u_strength":.75}, dtype="f2")
        values = np.frombuffer(field.read(alignment=1),np.float16).reshape(128,256,4)
        self.assertLess(float(values[:,:,0].min()),-0.01)
        self.assertGreater(float(values[:,:,0].max()),0.01)
        self.assertLessEqual(float(np.linalg.norm(values[:,:,:2].astype(float),axis=2).max()),1.501)
        result, pixels = renderer.bounded3(depth,source,(256,128))
        self.assertEqual(result.dtype,"f2")
        self.assertTrue(np.isfinite(np.frombuffer(result.read(alignment=1),np.float16)).all())
        # Existing edge corrections remain symmetric along a straight contour.
        np.testing.assert_array_equal(pixels[20,:,0],pixels[100,:,0])
        flat = renderer.texture(np.full((32,64),128,np.uint8))
        flat_result, pixels = renderer.bounded3(flat,source,(256,128))
        np.testing.assert_array_equal(pixels[:,:,0],128)
        blank = renderer.texture(np.full((128,256,3),128,np.uint8))
        unchanged, pixels = renderer.bounded3(depth,blank,(256,128))
        baseline, before = renderer.draw("UPSAMPLE_FRAGMENT_SRC", (256,128), {"u_depth":depth}, {"u_linear":1}, dtype="f2")
        np.testing.assert_array_equal(pixels,before)
        for texture in (source,depth,field,result,flat,flat_result,blank,unchanged,baseline):
            texture.release()

    def test_bounded3_ambiguity_rejection(self):
        renderer = Renderer()
        raw = np.zeros((32,64),np.uint8)
        raw[:,32:] = 255
        depth = renderer.texture(raw)
        single = np.zeros((128,256,3),np.uint8)
        single[:,128:] = 255
        competing = np.zeros_like(single)
        competing[:,124:132] = 255
        fields = []
        for guide in (single,competing):
            texture = renderer.texture(guide)
            field, _ = renderer.draw("edge_field", (256,128), {"u_depth":depth,"u_guide":texture}, {"u_radius":2.,"u_strength":.75}, dtype="f2")
            fields.append(np.frombuffer(field.read(alignment=1),np.float16).reshape(128,256,4).copy())
            field.release()
            texture.release()
        self.assertLess(float(fields[1][64,127:129,2].mean()),float(fields[0][64,127:129,2].mean()))
        depth.release()

    def test_bounded3_suppresses_tangent_wobble(self):
        renderer = Renderer()
        raw = np.zeros((32,64),np.uint8)
        raw[:,32:] = 255
        depth = renderer.texture(raw)
        field = np.zeros((128,256,4),np.float32)
        field[:,:,0] = np.where(np.arange(128)%2==0,.4,.8)[:,None]
        field[:,:,2] = 1.0
        ramp = np.clip((np.arange(256)+.5)/4-.5-31,0,1)
        field[:,:,3] = ramp[None,:]
        field_texture = renderer.texture(field)
        result, _ = renderer.draw("edge_coherent", (256,128), {"u_depth":depth,"u_field":field_texture}, {}, dtype="f2")
        after = np.frombuffer(result.read(alignment=1),np.float16).reshape(128,256,4).astype(float)
        x = 126
        before = np.clip((x+.5)/4-.5-31+field[20:100,x,0],0,1)
        self.assertLess(float(after[20:100,x,0].std()),float(before.std())*.6)
        # Refinement retains sub-8-bit precision, unlike the Bounded-2 target.
        self.assertGreater(float(np.max(np.abs(after[:,:,0]*255-np.round(after[:,:,0]*255)))),0.01)
        for texture in (depth,field_texture,result):
            texture.release()

    def test_contour_cleanup_reduces_depth_wobble(self):
        renderer = Renderer()
        y, x = np.mgrid[:128,:256]
        raw = np.clip((x-127.5)*.4+0.5+np.where(y%2==0,.12,-.12),0,1).astype(np.float32)
        depth = renderer.texture(raw)
        result, _ = renderer.draw("contour_cleanup",(256,128),{"u_depth":depth},{},dtype="f2")
        after = np.frombuffer(result.read(alignment=1),np.float16).reshape(128,256,4)[::-1,:,0].astype(float)
        self.assertLess(float(after[20:100,128].std()),float(raw[20:100,128].std())*.9)
        self.assertTrue(np.isfinite(after).all())
        self.assertGreaterEqual(float(after.min()),0.)
        self.assertLessEqual(float(after.max()),1.)
        depth.release()
        result.release()

    def test_contour_cleanup_preserves_flat_straight_and_thin(self):
        renderer = Renderer()
        straight = np.zeros((32,64),np.float32)
        straight[:,32:] = 1.
        thin = np.zeros_like(straight)
        thin[:,32] = 1.
        for raw in (np.full_like(straight,.5),straight,thin):
            depth = renderer.texture(raw)
            result, _ = renderer.draw("contour_cleanup",(64,32),{"u_depth":depth},{},dtype="f2")
            after = np.frombuffer(result.read(alignment=1),np.float16).reshape(32,64,4)[::-1,:,0]
            np.testing.assert_array_equal(after,raw)
            depth.release()
            result.release()


if __name__ == "__main__":
    unittest.main()
