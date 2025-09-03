# Game Engine in Jai
*Warning*: you might not be able to clone the project if all my GitHub LFS bandwidth has been used. I have to find a solution to put assets outside of the main repository.

Started as a toy engine project to learn Vulkan and advanced rendering techniques, this is now taking the direction of a fully fledged game engine.

There is still a lot to do on the graphics side of things, but currently I am directing my efforts on game stuff.

Supports Linux and Windows.

## Features:
* No "big idea" (e.g. ECS), simple and pragmatic entity system
* Graphics abstraction layer
* Shader hot reloading
* Asset hot reloading
* Highly backward and forward compatible serialization system using manual indices
* Simple editor with gizmos
* Simple CPU profiler
* Simple GPU profiler
* Skinned meshes
* Physically based opaque surface shading
* Image based lighting
* HDR textures
* Cascaded shadow maps
* Parallax occlusion mapping with self shadowing
* Bloom
* Omnidirectional shadow maps
* Clustered forward rendering

## To explore/implement next:
### Graphics:
* Global illumination
* Non pre-baked reflections
* GTAO
* Subsurface scattering
* Volumetric clouds
* Automatic texture transition barriers
* Variance shadow maps
* Particle system
### Editor:
* Texture viewer
### Core:
* Pipelining
* Hot reloading code
* Input system
### Animation:
* Animation system
* Animation graph (ideally a UE like graph that's more of a general purpose visual scripting tool)
* Animation joint attachments
### Physics:
* Collision detection queries (we can probably use a physics engine)
* Physics engine integration (probably Jolt)

## Goals
* Having a player running, jumping and mantling around (see Unreal Engine Advanced Locomotion System)
* Sponza running at 155 FPS with all point lights casting shadows

## Gallery
### Custom editor gizmos
![Gizmos](Screenshots/gizmo.gif)
### Parallax occlusion mapping, with self shadowing
![Parallax Occlusion Mapping With Self Shadowing](Screenshots/parallax_occlusion_mapping_with_shadows.gif)
### Custom file browser
![File Browser](Screenshots/file_browser.png)
### 1000 moving point lights running at 100 FPS (1080p)
> 60 FPS because of V-Sync, but GPU time varies between 10 to 11 ms, which is 90-100 FPS

![Light Ballet](Screenshots/light_ballet.png)
