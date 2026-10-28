# Omniverse: build a USD scene

A batch job that assembles a USD scene from a manifest, headless, in the Isaac Sim
container on a GPU node: meshes (OBJ, STL, FBX, glTF) converted with Kit's asset
converter, USD files referenced, URDF and MJCF robots imported with Isaac Sim's
importers, each placed, colored and given physics. No endpoint: the run completes
when the scene is written and fails when the build fails.

```
form ──► preprocessing ──► build script ──► build.py in the container ──► build/<scene>.usda + assets/ + build.json
         (checks, the SIF,  (GPU, image)     convert, import, place,              │
          the parts copied)                   apply physics, write USD            └──► a copy to the destination
```

## The manifest

```yaml
scene: yard.usda
up_axis: Z                   # Z (default) or Y
ground: true                 # a ground plane
objects:
  - name: crate
    file: parts/crate.obj    # relative to the source; .obj .stl .fbx .gltf .glb .usd* .urdf .xml
    position: [2, -0.6, 0.25]
    rotation: [0, 0, 15]     # degrees
    scale: 1
    physics: rigid           # rigid (falls, collides), static (collides, fixed) or none
    collision: convexHull    # convexHull, convexDecomposition, boundingCube, boundingSphere
    mass: 2                  # kg; else density (default 1000)
    velocity: [1.5, 0, 0]    # an initial throw
    color: [0.91, 0.30, 0.24]
  - name: pendulum
    file: robots/pendulum.urdf
    position: [3.5, 0, 0]
    fix_base: true
```

The manifest comes from the form, else from the source directory's `manifest.yaml`,
else the bundled example builds: a ramp, three crates, a ball rolling down and a
two-link pendulum (`app/examples/build/`). The whole format is at the top of
`app/build.py`.

## Form

| Field | Default | Notes |
|---|---|---|
| GPU host; submit to the scheduler, cores, GPUs, directives | login node, 8 cores, 0 GPUs | as the render workflow |
| Manifest | empty | YAML as above |
| Files in and out | off | a switch to use a bucket, the bucket, the parts source and the scene destination (paths in the bucket, or absolute on the cluster) |
| Software | Singularity, `${HOME}/pw/software` | the runtime, its image or SIF, the install directory |

## Outputs

`build/<scene>` with `assets/` beside it (the converted meshes and imported robots it
references by relative path) and `build.json` (objects, bodies, joints). Give that
directory, or the destination it was copied to (`<destination>/<run slug>/`), as the
render workflow's source. The run's log names the scene; `build.exit` holds the
script's exit status, which the run's last step reads.
