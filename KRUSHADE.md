# Godot Krushade — Mobile motion vectors

This fork carries native motion-vector support for ordinary Mobile renderer
compositors. It does **not** embed TowerOfMayhem or its custom TAA shader.

## Branch and provenance

- Development branch: `4.7` (not `master`).
- Upstream base: `godotengine/godot` commit
  `f6ab5db28b9d989a3ae710d57410a123cf0e4b23`, the fetched `4.7` tip
  on 2026-09-10; `version.py` reports **4.7.3-rc**.
- Ported from the native patch originally tested on
  `ed1daf0bf001b61586d9930840f2f1394092c079` (4.7.2).
- Upstream changes between these revisions did not touch the seven patched
  files. Native changes preserve the tested implementation, with one shader
  preprocessor indentation correction to follow the GLSL formatting rules.

## Rendering contract

A `CompositorEffect` with `needs_motion_vectors = true` now requests an owned
Mobile velocity target. Consume it at `EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT`.
`RenderSceneBuffersRD.get_velocity_texture()` / `get_velocity_layer(0)` expose it;
`has_texture("mobile_compositor_velocity", "velocity")` identifies this contract.

| Channel | Meaning |
| --- | --- |
| RGB | Current minus previous NDC XYZ, Y up |
| A | 1 for opaque/cutout coverage, 0 for cleared background |
| Format | RGBA16F, single sample, internal 3D resolution |

Convert XY to UV displacement with `velocity.xy * vec2(0.5, -0.5)`.
Vectors include camera jitter; consumers must handle that consistently. This is
not the Forward+ RG velocity encoding. Previous native model transforms and
GPU-skinned positions supply rigid and skeletal movement without clone meshes.

Fast path writes colour and velocity together in the opaque MRT pass, without
redrawing geometry or allocating a separate velocity depth texture. It applies
to mono, no-MSAA, flat-colour/no-fog viewports without XR/debug overrides.
Other configurations retain the separate velocity path. Set
`rendering/renderer/mobile_motion_vectors_mrt=false` for that diagnostic path.
The target is reused, recreated on resize, and released when no longer requested.

### Source map

All paths below are under `servers/rendering/renderer_rd/`:

- `forward_mobile/render_forward_mobile.{cpp,h}`: request handling and passes.
- `forward_mobile/scene_shader_forward_mobile.{cpp,h}`: shader/pipeline variants.
- `shaders/forward_mobile/scene_forward_mobile.glsl`: current/previous positions,
  velocity output on colour attachment 1.
- `storage_rd/render_scene_buffers_rd.{cpp,h}`: target access/lifetime.

## Build

Use normal Godot 4.7 build dependencies (SCons, compiler, platform dependencies).
A tested Linux configuration is:

```sh
scons -j24 platform=linuxbsd target=editor arch=x86_64 \
  use_llvm=yes linker=lld debug_symbols=no optimize=speed lto=none
bin/godot.linuxbsd.editor.x86_64.llvm --editor --path ../TowerOfMayhem
```

A custom editor is required; opening the project with an unmodified system Godot
does not load these native changes. The project Python launcher is optional.
Android exports likewise need templates built from this fork; existing 4.7.2
phone artifacts are not automatically upgraded by cloning or building here.

## GPU regression fixture

The fixture is standalone and performs **test-only synchronous GPU readbacks**.
Requires a real Vulkan GPU/display, not `--headless`. Run from the repository root:

```sh
bin/godot.linuxbsd.editor.x86_64.llvm \
  --path misc/krushade/mobile_motion_vectors/fixture \
  --rendering-method mobile --rendering-driver vulkan \
  --script res://probe.gd -- /tmp/krushade-motion-vectors.json
python3 misc/krushade/mobile_motion_vectors/validate_fixture.py \
  /tmp/krushade-motion-vectors.json --expect-mrt
```

Forty samples cover stationary, rigid XY, camera XY, bone-only XY, stopped bones,
rigid depth, projection jitter, request off/on, and viewport resize. The validator
checks numerical vectors, background clearing, allocation reuse/release, and MRT
absence of a separate velocity depth texture, not just a non-null RID.

## Validation of this 4.7 port (2026-09-10)

- Linux x86_64 editor: full LLVM build passed; final shader rebuild passed.
- Desktop Vulkan / NVIDIA GeForce RTX 5070 Ti: **40/40 numeric fixture samples**
  across all ten phases passed, with MRT enabled and no separate velocity depth.
- TowerOfMayhem normal TAA integration: **19 checks, zero failures** with this
  newly built executable. Includes off/on, level reload, allocation-failure
  fallback, history reuse, and one resolve/copy per frame with no duplicates.
- These are desktop correctness checks, not an FPS benchmark. Android 4.7.3-rc
  templates were not built or installed; XR/multiview was not device-tested.

## Limits

Transparent objects and arbitrary shader-uniform deformation (such as wind whose
previous state is not retained) are not automatically tracked. XR/multiview paths
are preserved but not device-tested. No universal image-quality, mobile FPS, or
zero-cost claim: velocity attachments and previous skinning state have costs.
The TAA resolve, history and jitter controller remain in the game project.
