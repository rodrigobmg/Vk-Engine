# Vulkan Based Rendering Engine
*Warning*: you might not be able to clone the project if all my GitHub LFS bandwidth has been used. I have to find a solution to put assets outside of the main repository.

Toy engine project to learn Vulkan and advanced rendering techniques.

Supports Linux and Windows.

## Features:
* Abstraction layer
* Shader hot reloading
* Asset hot reloading
* Highly backward and forward compatible serialization system
* Physically based opaque surface shading
* Image based lighting
* HDR textures
* Cascaded shadow maps
* Parallax occlusion mapping with self shadowing
* Bloom
* Omnidirectional shadow maps
* Simple editor with gizmos
* Simple GPU profiler
* Skinned meshes
* Clustered forward rendering

## To explore/implement next:
* Global illumination
* Non pre-baked reflections
* GTAO
* Subsurface scattering
* Volumetric clouds
* Automatic texture transition barriers
* Texture viewer
* Variance shadow maps

## Goals
* Sponza running at 155 FPS with all point lights casting shadows

## Gallery
### Custom editor gizmos
![Gizmos](Screenshots/gizmo.gif)
### Parallax occlusion mapping, with self shadowing
![Parallax Occlusion Mapping With Self Shadowing](Screenshots/parallax_occlusion_mapping_with_shadows.gif)
### Custom file browser
![File Browser](Screenshots/file_browser.png)
### 1000 moving point lights running at 100 FPS (1080p)
![Light Ballet](Screenshots/light_ballet.png)
