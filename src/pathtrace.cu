#include <cstdio>
#include <cuda.h>
#include <cmath>
#include <thrust/random.h>

#include "sceneStructs.h"
#include "scene.h"
#include "glm/glm.hpp"
#include "glm/gtx/norm.hpp"
#include "utilities.h"
#include "pathtrace.h"
#include "intersections.h"
#include "interactions.h"
#include "../stream_compaction/efficient.h"

#define FILENAME (strrchr(__FILE__, '/') ? strrchr(__FILE__, '/') + 1 : __FILE__)
#define checkCUDAError(msg) checkCUDAErrorFn(msg, FILENAME, __LINE__)
void checkCUDAErrorFn(const char *msg, const char *file, int line) {
	cudaError_t err = cudaGetLastError();
	if (cudaSuccess == err) {
		return;
	}

	fprintf(stderr, "CUDA error");
	if (file) {
		fprintf(stderr, " (%s:%d)", file, line);
	}
	fprintf(stderr, ": %s: %s\n", msg, cudaGetErrorString(err));
	exit(EXIT_FAILURE);
}

__host__ __device__ thrust::default_random_engine random_engine(
	int iter, int index = 0, int depth = 0) {
	int h = utilhash((1 << 31) | (depth << 20) | iter) ^ utilhash(index);
	return thrust::default_random_engine(h);
}

//Kernel that writes the image to the OpenGL PBO directly.
__global__ void sendImageToPBO(uchar4* pbo, glm::ivec2 resolution,
	int iter, glm::vec3* image) {
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	if (x < resolution.x && y < resolution.y) {
		int index = x + (y * resolution.x);
		glm::vec3 pix = image[index];

		glm::ivec3 color;
		color.x = glm::clamp((int)(pix.x / iter * 255.0), 0, 255);
		color.y = glm::clamp((int)(pix.y / iter * 255.0), 0, 255);
		color.z = glm::clamp((int)(pix.z / iter * 255.0), 0, 255);

		// Each thread writes one pixel location in the texture (textel)
		pbo[index].w = 0;
		pbo[index].x = color.x;
		pbo[index].y = color.y;
		pbo[index].z = color.z;
	}
}

static Scene *hst_scene = NULL;
static glm::vec3 *dev_image = NULL;
static Ray* dev_rays = NULL;
static Ray* dev_compactionOutput = NULL;
static Geom* dev_geoms = NULL;
static MovingGeom* hst_mgeoms = NULL;
static MovingGeom* dev_mgeoms = NULL;
static Material* dev_materials = NULL;

void pathtraceInit(Scene *scene) {
	hst_scene = scene;
	const Camera &cam = hst_scene->state.camera;

	hst_mgeoms = &(hst_scene->mgeoms)[0];

	const Material *materials = &(hst_scene->materials)[0];
	const int pixelcount = cam.resolution.x * cam.resolution.y;

	cudaMalloc(&dev_image, pixelcount * sizeof(glm::vec3));
	cudaMemset(dev_image, 0, pixelcount * sizeof(glm::vec3));

	cudaMalloc(&dev_rays, pixelcount * sizeof(Ray));
	cudaMemset(dev_rays, 0, pixelcount * sizeof(Ray));

	cudaMalloc(&dev_compactionOutput, pixelcount * sizeof(Ray));
	cudaMemset(dev_compactionOutput, 0, pixelcount * sizeof(Ray));

	cudaMalloc(&dev_materials, pixelcount * sizeof(Material));
	cudaMemcpy(dev_materials, materials, hst_scene->materials.size() * sizeof(Material), cudaMemcpyHostToDevice);

	checkCUDAError("pathtraceInit");
}

void pathtraceFree() {
	cudaFree(dev_image); // no-op if dev_image is null
	cudaFree(dev_rays);
	cudaFree(dev_compactionOutput);
	cudaFree(dev_geoms);
	cudaFree(dev_mgeoms);
	cudaFree(dev_materials);

	checkCUDAError("pathtraceFree");
}

/**
 * To accomodate motion blur, we have to load the MotionGeom data to the Geom data on each iteration.
 * TODO: Make changes that avoid using this to reduce memory overhead.
 */
Geom *LoadGeoms(MovingGeom *mgeoms, int frame, int numberOfObjects) {	
	Geom *geoms = (Geom*)malloc(numberOfObjects * sizeof(Geom));
	for (int i = 0; i < numberOfObjects; i++) {
		geoms[i].type = hst_mgeoms[i].type;
		geoms[i].materialid = hst_mgeoms[i].materialid;
		geoms[i].translation = hst_mgeoms[i].translations[frame];
		geoms[i].rotation = hst_mgeoms[i].rotations[frame];
		geoms[i].scale = hst_mgeoms[i].scales[frame];
		geoms[i].transform = hst_mgeoms[i].transforms[frame];
		geoms[i].inverseTransform = hst_mgeoms[i].inverseTransforms[frame];
		geoms[i].invTranspose = hst_mgeoms[i].inverseTransposes[frame];
	}

	cudaMalloc((void**)&dev_geoms, numberOfObjects * sizeof(Geom));
	cudaMemcpy(dev_geoms, geoms, numberOfObjects * sizeof(Geom), cudaMemcpyHostToDevice);

	return geoms;
}

/**
 * Creates a ray through each pixel on the screen.
 * Depth of Field: http://mzshehzanayub.blogspot.com/2012/10/gpu-path-tracer.html
 */
__global__ void InitializeRays(Camera cam, int iter, Ray* rays) {
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;
	int index = x + (y * cam.resolution.x); // index in ray array
	
	thrust::default_random_engine rng = random_engine(iter, index, 0);
	thrust::uniform_int_distribution<float> u01(0.0f, 1.0f);
	thrust::uniform_int_distribution<float> uHalf(-0.5f, 0.5f);

	if (cam.dof) {
		// Depth of field
		glm::vec3 horizontal, middle, vertical;
		glm::vec3 pointOnUnitImagePlane, pointOnTrueImagePlane;

		// Compute point on image plane, then plane at focal distance
		horizontal = glm::cross(cam.view, cam.up) * glm::sin(-cam.fov.x);
		vertical = glm::cross(glm::cross(cam.view, cam.up), cam.view) * glm::sin(-cam.fov.y);
		middle = cam.position + cam.view;

		pointOnUnitImagePlane = middle + (((2.0f * ((uHalf(rng) + x) / (cam.resolution.x - 1))) - 1.0f) 
			* horizontal) + (((2.0f * ((uHalf(rng) + y) / (cam.resolution.y - 1))) - 1.0f) * vertical);
		pointOnTrueImagePlane = cam.position + ((pointOnUnitImagePlane - cam.position) * cam.focalDistance);

		 // Sample a random point on the lense
		float angle = TWO_PI * u01(rng);
		float distance = cam.apertureRadius * glm::sqrt(u01(rng));
		glm::vec2 aperture(glm::cos(angle) * distance, glm::sin(angle) * distance);

		rays[index].origin = cam.position + (aperture.x * glm::cross(cam.view, cam.up) + (aperture.y * glm::cross(glm::cross(cam.view, cam.up), cam.view)));;
		rays[index].direction = glm::normalize(pointOnTrueImagePlane - rays[index].origin);
	}
	else {
		//No depth of field
		float halfResX, halfResY;

		halfResX = cam.resolution.x / 2.0f;
		halfResY = cam.resolution.y / 2.0f;

		rays[index].origin = cam.position;
		rays[index].direction = cam.view + ((-(halfResX - x + uHalf(rng)) 
			* sin(cam.fov.x)) / halfResX) * glm::cross(cam.up, cam.view) + (((halfResY - y + uHalf(rng)) * sin(cam.fov.y)) / halfResY) * cam.up;
	}

	rays[index].color = glm::vec3(1.0f);
	rays[index].pixel_index = index;
	rays[index].alive = true;
	rays[index].inside = false;
}

/**
 * Traces an individual array for one bounce.
 */
__global__ void TraceBounce(int iter, int depth, glm::vec3 *image, Ray *rays, const Geom *geoms, const int numberOfObjects, const Material *materials) {
	// Thread index corresponds to the ray, pixel index is saved member of the ray
	int index = blockIdx.x * blockDim.x * blockDim.y + threadIdx.y * blockDim.x + threadIdx.x;
	int pixelIndex = rays[index].pixel_index, minGeomIndex = -1;
	float t = -1.0f, minT = FLT_MAX;
	glm::vec3 minNormal, minIntersectionPoint;

	for (int i = 0; i < numberOfObjects; i++) {
		glm::vec3 normal, intersectionPoint;

		if (geoms[i].type == CUBE) {
			t = boxIntersectionTest(geoms[i], rays[index], intersectionPoint, normal);
		}
		else if (geoms[i].type == SPHERE) {
			t = sphereIntersectionTest(geoms[i], rays[index], intersectionPoint, normal);
		}
		else {
			printf("Invalid geometry.");
			continue;
		}

		// Find the closest intersection
		if (t != -1.0f && minT > t) {
			minT = t;
			minNormal = normal;
			minIntersectionPoint = intersectionPoint;
			minGeomIndex = i;
		}
	}

	if (minGeomIndex == -1) {
		// Nothing was hit
		rays[index].alive = false;
		image[pixelIndex] += glm::vec3(0.0f);
	}
	else {
		int materialIndex = geoms[minGeomIndex].materialid;

		// Either we hit a light, or we scatter again
		if (materials[materialIndex].emittance > EPSILON) {
			rays[index].alive = false;
			image[pixelIndex] += rays[index].color * materials[materialIndex].color * materials[materialIndex].emittance;
		}
		else {
			thrust::default_random_engine rng = random_engine(iter, pixelIndex, depth);
			scatterRay(rays[index], rays[index].color, minIntersectionPoint, minNormal, materials[materialIndex], rng);
		}
	}
}

/**
 * Wrapper for the __global__ call that sets up the kernel calls and does a ton
 * of memory management
 */
void pathtrace(uchar4 *pbo, int frame, int iter, int maxIter) {
	const int traceDepth = hst_scene->state.traceDepth;
	const Camera &cam = hst_scene->state.camera;
	const int numberOfObjects = hst_scene->mgeoms.size();
	const int pixelcount = cam.resolution.x * cam.resolution.y;

	const int blockSideLength = 8;
	const int blockSideLengthSquare = pow(blockSideLength, 2);
	const dim3 blockSize(blockSideLength, blockSideLength);
	const dim3 blocksPerGrid(
		(cam.resolution.x + blockSize.x - 1) / blockSize.x,
		(cam.resolution.y + blockSize.y - 1) / blockSize.y);

	///////////////////////////////////////////////////////////////////////////

	if (iter == 1) {
		// If the scene has reset, then reset objects in motion to original positions
		for (int i = 0; i < numberOfObjects; i++) {
			hst_mgeoms[i].translations[0] = hst_mgeoms[i].translations[2];
		}
	}

	// Motion blur
	Geom *geoms;
	if (cam.blur) {
		geoms = LoadGeoms(hst_mgeoms, frame, numberOfObjects);

		for (int i = 0; i < numberOfObjects; i++) {
			if (hst_mgeoms[i].motionBlur) {
				motionBlur(hst_mgeoms, hst_mgeoms[i].id, iter, maxIter);
			}
		}
	}
	else {
		geoms = LoadGeoms(hst_mgeoms, 2, numberOfObjects);
	}

	InitializeRays<<<blocksPerGrid, blockSize>>>(cam, iter, dev_rays);
	checkCUDAError("InitializeRays");

	int currentDepth = 0, rayCount = pixelcount;
	while (rayCount > 0 && currentDepth < traceDepth) {
		dim3 thread_blocksPerGrid = (rayCount + blockSideLengthSquare - 1) / blockSideLengthSquare;
		/*cudaEvent_t start, stop;
		float ms_time = 0.0f;

		cudaEventCreate(&start);
		cudaEventCreate(&stop);*/

		//cudaEventRecord(start);
		TraceBounce<<<thread_blocksPerGrid, blockSize>>>(iter, currentDepth, dev_image, dev_rays, dev_geoms, numberOfObjects, dev_materials);
		//cudaEventRecord(stop);
		//cudaEventSynchronize(stop);
		//cudaEventElapsedTime(&ms_time, start, stop);
		checkCUDAError("TraceBounce");

		rayCount = StreamCompaction::Efficient::Compact(rayCount, dev_compactionOutput, dev_rays);
		/*if (iter == 1) {
			printf("Depth %d: Trace took %.5fms and %d out of %d rays remain.\n", currentDepth, ms_time, rayCount, pixelcount);
		}*/
		
		cudaMemcpy(dev_rays, dev_compactionOutput, rayCount * sizeof(Ray), cudaMemcpyDeviceToDevice);
		currentDepth++;
	}

	///////////////////////////////////////////////////////////////////////////

	// Send results to OpenGL buffer for rendering
	sendImageToPBO<<<blocksPerGrid, blockSize>>>(pbo, cam.resolution, iter, dev_image);
	checkCUDAError("sendImageToPBO");

	// Retrieve image from GPU
	cudaMemcpy(hst_scene->state.image.data(), dev_image,
		pixelcount * sizeof(glm::vec3), cudaMemcpyDeviceToHost);
	checkCUDAError("cudaMemcpy");

	// Free geoms here because we are going to keep allocating it on each iteration atm
	free(geoms);
}

