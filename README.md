CUDA Path Tracer
================

**University of Pennsylvania, CIS 565: GPU Programming and Architecture, Project 3**

* Bradley Crusco
* Tested on: Windows 10, i7-3770K @ 3.50GHz 16GB, 2 x GTX 980 4096MB (Personal Computer)

## Description
An interactive GPU accelerated path tracer with support for diffuse, specular, mirrored, and refractive surfaces. Additional features include depth of field and motion blur effects.
![](img/cornell_main_20k.png "Cornell Box")

Video of real time interaction: [https://youtu.be/Ja_5wvhphvI](https://youtu.be/Ja_5wvhphvI?rel=0)

## Features

### Diffuse Surfaces
![](img/cornell_diffuse.2015-09-27_02-29-25z.5000samp.png "Diffuse Sphere")

Diffuse surfaces are supported using a cosine weighted random direction calculation.

### Perfectly Specular Reflective Surfaces
![](img/cornell_mirror.2015-09-27_00-58-26z.5000samp.png "Perfectly Specular Mirror Sphere")

Perfectly specular surfaces give a mirrored effect and are created by combining a specular light component with the calculation of the direction of a ray off a mirrored object.

### Work Efficient Stream Compaction
Performance of the path tracer is optimized by using the work efficient stream compaction method found in [GPU Gems 3 Chapter 39: Parallel Prefix Sum (Scan) with CUDA](http://http.developer.nvidia.com/GPUGems3/gpugems3_ch39. html) on the array of rays. After each pass through all the rays, I check if a ray has been terminated (either because it hit a light or it traveled the maximum distance without intersecting with an object) and mark them as such. The stream compaction algorithm then takes this array and removes all of the terminated rays. This means at each pass through the rays, our collection of remaining ones to trace with becomes smaller, allowing us to free GPU threads for arrays that are still alive. More on this topic can be found in the [analysis](https://github.com/bcrusco/Project3-CUDA-Path-Tracer/blob/master/README.md#analysis) section bellow.

### Depth of Field
![](img/cornell_dof.2015-09-27_01-18-07z.5000_annotatedsamp.png "Depth of Field")

* **Overview**: When depth of field is disabled, my path tracer acts line a "pinhole camera". All the arrays come from a single point and are shot into each pixel of an image plane. Depth of field integrates over a lens to achieve its effect, dropping the pinhole implementation. I added two new configuration options to the camera in my scene files, focal distance and aperture radius. Focal distance specifies how far away from the camera is the image in focus, and replaces the idea of the image plane. And the aperture radius determines the severity of the effect (the blur of everything not at the focal distance).
* **Performance Impact**: Negligible. There is a few more calculations for depth of field than the standard pinhole implementation, but they are not major and they only take place when the rays are being created for the first bounce. So, the calculation will happen only once per iteration.
* **GPU vs. CPU Implementation**: The calculations for depth of field take place during the creation of my rays. This is the part of the code where the GPU and CPU implementations are most similar (the only difference being we can do it in parallel on the GPU). The specific depth of field calculations should be the same for either implementation, but it will just run faster on the GPU.

### Non-Perfect Specular Surfaces
![](img/cornell_np_spec.2015-09-26_23-41-17z.5000samp.png "Non-Perfect Specular Surface")

* **Overview**: Non-perfect specular surfaces, which gives a glossy effect, are created using a probability distribution between the diffuse and specular component of a material. First a probability of either a diffuse or a specular ray bounce occurring is calculating by weighting the intensity of the diffuse and specular color values respectively. A random value between 0 and 1 is then generated, which I use to choose a bounce type. The corresponding ray bounce direction is then calculated, as is the color, which is the given color provided by the scene file multiplied by the inverse probability that this bounce occurred.
* **Performance Impact**: Negligible. The only additional calculation to be done is the calculation of the ratio between both color intensities. There is a conditional, which may have performance impact, but this method only calculates one color and one ray bounce just like the mirrored and diffuse implementations.
* **GPU vs. CPU Implementation**: A CPU implementation would likely be recursive, where my GPU implementation is not. Because of this I use a probability calculation to determine how to bounce and only do the bounce once. Since the CPU implementation is recursive, it would likely trace both the specular and diffuse bounces instead of just picking one, and then use the ratio to determine the weights of the resulting color. So for the CPU implementation I would expect dramatically more performance requirements for this feature than my GPU implementation.

### Refractive Surfaces with Fresnel Effects
![](img/cornell_mirror.2015-09-27_00-58-26z.5000samp_annotated.png "Glass Sphere with Fresnel Effects")

* **Overview**: This is calculated in much the same way as non-perfect specular surfaces. We figure out a probability that a ray hitting our refractive surface will either bounce off and reflect or pass into and refract through the object. If it reflects, we calculate the mirrored reflection direction, and if it refracts we calculate the ray direction using [Snell's law](https://en.wikipedia.org/wiki/Snell% 27s_law). The main difference is in the calculation of this probability. We calculate the Fresnel reflection coefficient using [Schlick's approximation](https://en.wikipedia.org/wiki/Schlick% 27s_approximation) (the inverse of which is the refraction coefficient). An index of refraction, specified in the scene files, determines the refractive properties of the respective material. Air has an index of refraction of 1, and glass about 2.2. It is important to keep track of whether a ray is going into an object or coming out of it, as the indexes are used in a ratio, and the ordering changes depending on what is being exited and what is being entered.
* **Performance Impact**: Significant. Compared to non-perfect specular surfaces, we have many more calculations to do to figure out the respective reflection and refraction coefficients. In addition, if a ray hits a refractive object at a perpendicular angle, the ray is always reflected, regardless of our reflection and refraction coefficients. This is another additional calculation that adds to the performance demands.
* **GPU vs. CPU Implementation**: As far as comparing my GPU implementation to what I'd expect a CPU implementation to be, it'd be the same as the comparison for non-perfect specular surfaces, except in this case the performance increase would be much more significant because it would have to make the additional calculations for the Fresnel coefficients.
* **How to Optimize**: To keep track of whether a ray was inside or outside of an object so I could know how to use the index of refraction coefficients (the air and the other object) I added a boolean to my Ray struct that held this state. This significantly added to my memory overhead because I'm using so many Ray's. I'd like to come up with a way to determine this property on the fly without saving it to further optimize performance.

### Motion Blur
![](img/cornell_blur.2015-09-27_01-51-43z.5000samp.png "Motion Blur")
* **Overview**: Motion blur is very conceptually simple. We merely transform an object's position over the course of our render. This creates a blur effect because we are sampling the object at different locations, which creates a blurry trail as the object moves across the screen. Implementation was less trivial however, as originally I was not planning to support it and my geometry implementation did not support moving objects. To avoid changing a significant amount of code, I made a MovingGeom struct in addition to my original Geom struct to represent geometry that was moving. Since my path tracing implementation didn't have a concept of this MovingGeom, on every iteration before I begin path tracing I update the standard Geom of any object marked to be blurred, then trace as if it was static. The one additional change that was made to support this was a change to my scene files. It now requires "frame" tags to be added before transformation data. Two sets of data are expected, labeled "frame 0" and "frame 1", respectively. For objects that have motion blur enabled for them, these represent the starting and ending positions of the object.
* **Performance Impact**: Significant. The impact on the actual path tracing itself is nonexistent. There's no additional calculations, the objects we are intersecting with just happen to be in a different location. My specific workaround implementation to support a MovingGeom has significant consequences for memory bandwidth, as it demands that I load new Geom data on each iteration. Geoms can be very large, and are already a memory bottleneck, so this is less than ideal. If I want to eventually support arbitrary mesh models, I'll have to come up with a new implementation.
* **GPU vs. CPU Implementation**: The way I am calculating the motion blur effect is independent of how I am doing my path tracing, so there should be no difference between the CPU and GPU implementations.
* **How to Optimize**: As said above, the main space to optimize is the memory management of the MovingGeoms and Geoms. One more simple optimization, that is short of changing the entire project to support MovingGeoms, that might have a large effect is to store the MovingGeoms on the device memory instead of the host memory. As of now a transfer from host to device is required on every iteration, causing a big bottleneck. That bottleneck would at least be eliminated with this change.


## Analysis
### Stream Compaction: Open vs. Closed Scenes

![](img/Project 3 Analysis 1.png "Active Threads Remaining at Trace Depth (Open vs. Closed Scene")
![](img/Project 3 Analysis 2.png "Trace Execution Time at Trace Depth (Open vs. Closed Scene")

The two above charts compare an open cornell box (one of the walls is missing) vs. a closed box. The first thing we can see from these charts, especially the chart plotting active threads vs. trace depth, is that the stream compaction doesn't really kick in until the second bounce. For the open scene we see the biggest change between depth 0 to 1 and 1 to 2, before it starts to decrease less rapidly. It makes sense that we do not see too major of a drop off at index 0, because there hasn't yet been enough bounces for rays to reasonably terminate.

Notice also how the closed scene data has a very gentle curve across the entire data set, compared to the sharp start off at the start for the open scene that then comes in line with the gentle curve. This shows a significant amount of rays that are bouncing out of the scene entirely.

Regarding execution time, you can see that it correlates almost exactly with the active threads data. This shows us something fairly obvious, that it takes less time to trace over all the rays when there are less of them. This fact isn't very important here however, since the speedup is the result of losing rays that would otherwise contribute to our image.

### Stream Compaction: Compaction vs. No Compaction

![](img/Project 3 Analysis 3.png "Trace Execution Time at Trace Depth for an Open Scene (Compaction vs. No Compaction")
![](img/Project 3 Analysis 4.png "Trace Execution Time at Trace Depth for a Close Scene (Compaction vs. No Compaction")

These above two charts compare the execution time of a trace across all remaining rays when stream compaction is enabled and disabled. In the case where stream compaction is disabled, in the ray bounce function itself I check, after it has already been launched, if it has been terminated. If so, then return. This stops the tracer from incorrectly calculating more bounces after the ray has been terminated, but keeps the overhead of the kernel launches that we are trying to avoid through compaction.

The second chart, comparing compaction vs. no compaction for a closed scene, is the most important of the two, because the data in open scene chart is heavily influenced by the fact that rays are terminating early because they are leaving the scene through the open wall. Although the no compaction implementation isn't doing any more calculations than the stream compaction implementation, you can see that over time the gap between the two continues to widen. This is a great illustration of how the overhead of managing threads can drag down performance if it isn't managed correctly. Performance suffers because threads that actually need to execute will be waiting on launched threads that should be dead to figure out that they have nothing to do and free up GPU space for other rays.

## Interactive Controls

* Esc to save an image and exit.
* Space to save an image. Watch the console for the output filename.
* W/A/S/D and R/F move the camera. Arrow keys rotate.
* B activates and deactivates motion blur for a scene. Only works if at least one object in the scene is blur enabled.
* 0, activates and deactivates depth of field. 1 decreases focal distance, 2 increases. 3 decreases aperture radius, 3 increases.

## Scene File Format

This project uses a custom scene description format. Scene files are flat text
files that describe all geometry, materials, lights, cameras, and render
settings inside of the scene. Items in the format are delimited by new lines,
and comments can be added using C-style `// comments`.

Materials are defined in the following fashion:

* MATERIAL (material ID) //material header
* RGB (float r) (float g) (float b) //diffuse color
* SPECX (float specx) //specular exponent
* SPECRGB (float r) (float g) (float b) //specular color
* REFL (bool refl) //reflectivity flag, 0 for no, 1 for yes
* REFR (bool refr) //refractivity flag, 0 for no, 1 for yes
* REFRIOR (float ior) //index of refraction for Fresnel effects
* SCATTER (float scatter) //scatter flag, 0 for no, 1 for yes
* ABSCOEFF (float r) (float b) (float g) //absorption coefficient for scattering
* RSCTCOEFF (float rsctcoeff) //reduced scattering coefficient
* EMITTANCE (float emittance) //the emittance of the material. Anything >0
  makes the material a light source.

Cameras are defined in the following fashion:

* CAMERA //camera header
* RES (float x) (float y) //resolution
* FOVY (float fovy) //vertical field of view half-angle. the horizonal angle is calculated from this and the reslution
* ITERATIONS (float interations) //how many iterations to refine the image,
  only relevant for supersampled antialiasing, depth of field, area lights, and
  other distributed raytracing applications
* DEPTH (int depth) //maximum depth (number of times the path will bounce)
* FILE (string filename) //file to output render to upon completion
* EYE (float x) (float y) (float z) //camera's position in worldspace
* VIEW (float x) (float y) (float z) //camera's view direction
* UP (float x) (float y) (float z) //camera's up vector
* BLUR (bool blur) //motion blur flag for the entire scene, 0 for no, 1 for yes
* DOF (bool dof) //depth of field flag, 0 for no, 1 for yes
* FD (float fd) //focal distance for depth of field
* AR (float ar) //aperture radius for depth of field

Objects are defined in the following fashion:

* OBJECT (object ID) //object header
* (cube OR sphere OR mesh) //type of object, can be either "cube", "sphere", or
  "mesh". Note that cubes and spheres are unit sized and centered at the
  origin.
* material (material ID) //material to assign this object
* BLUR (bool blur) //motion blur flag for individual object, 0 for no, 1 for yes
* frame (int framenum) //0 or 1. Used for motion blur. Specify start and end transforms
* TRANS (float transx) (float transy) (float transz) //translation
* ROTAT (float rotationx) (float rotationy) (float rotationz) //rotation
* SCALE (float scalex) (float scaley) (float scalez) //scale
