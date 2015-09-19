#pragma once

#include "intersections.h"

// CHECKITOUT
/**
 * Computes a cosine-weighted random direction in a hemisphere.
 * Used for diffuse lighting.
 */
__host__ __device__
glm::vec3 calculateRandomDirectionInHemisphere(
        glm::vec3 normal, thrust::default_random_engine &rng) {
    thrust::uniform_real_distribution<float> u01(0, 1);

    float up = sqrt(u01(rng)); // cos(theta)
    float over = sqrt(1 - up * up); // sin(theta)
    float around = u01(rng) * TWO_PI;

    // Find a direction that is not the normal based off of whether or not the
    // normal's components are all equal to sqrt(1/3) or whether or not at
    // least one component is less than sqrt(1/3). Learned this trick from
    // Peter Kutz.

    glm::vec3 directionNotNormal;
    if (abs(normal.x) < SQRT_OF_ONE_THIRD) {
        directionNotNormal = glm::vec3(1, 0, 0);
    } else if (abs(normal.y) < SQRT_OF_ONE_THIRD) {
        directionNotNormal = glm::vec3(0, 1, 0);
    } else {
        directionNotNormal = glm::vec3(0, 0, 1);
    }

    // Use not-normal direction to generate two perpendicular directions
    glm::vec3 perpendicularDirection1 =
        glm::normalize(glm::cross(normal, directionNotNormal));
    glm::vec3 perpendicularDirection2 =
        glm::normalize(glm::cross(normal, perpendicularDirection1));

    return up * normal
        + cos(around) * over * perpendicularDirection1
        + sin(around) * over * perpendicularDirection2;
}

/**
* Scatter a ray with some probabilities according to the material properties.
* For example, a diffuse surface scatters in a cosine-weighted hemisphere.
* A perfect specular surface scatters in the reflected ray direction.
* In order to apply multiple effects to one surface, probabilistically choose
* between them.
*
* The visual effect you want is to straight-up add the diffuse and specular
* components. You can do this in a few ways. This logic also applies to
* combining other types of materias (such as refractive).
* - (NOT RECOMMENDED - converges slowly or badly especially for pure-diffuse
*   or pure-specular. In principle this correct, though.)
*   Always take a 50/50 split between a diffuse bounce and a specular bounce,
*   but multiply the result of either one by 1/0.5 to cancel the 0.5 chance
*   of it happening.
* - Pick the split based on the intensity of each color, and multiply each
*   branch result by the inverse of that branch's probability (same as above).
*
* This method applies its changes to the Ray parameter `ray` in place.
* It also modifies the color `color` of the ray in place.
*
* You may need to change the parameter list for your purposes!
*/
__host__ __device__
void scatterRay(
        Ray &ray,
        glm::vec3 &color,
        glm::vec3 intersect,
        glm::vec3 normal,
        const Material &m,
        thrust::default_random_engine &rng) {
	if (m.hasReflective) {
		//First must determine if this is perfectly specular or not
		// is this only when there's an exponent? or when the diffuse is zero?
		// for now i will go with the exponent being non zero
		glm::vec3 specularColor = m.specular.color;
		glm::vec3 diffuseColor = m.color;
		float specularExponent = m.specular.exponent;
		if (specularExponent != 0) {
			// non perfect
			float thetaS, phiS;
			thrust::uniform_real_distribution<float> u01(0, 1);
			float xi1 = u01(rng), xi2 = u01(rng); //random values between 0 and 1
			glm::vec3 direction;
			
			thetaS = glm::acos(1.0f / (pow(xi1, specularExponent + 1)));
			phiS = 2.0f * PI * xi2;
			direction.x = glm::cos(phiS) * glm::sin(thetaS);
			direction.y = glm::sin(phiS) * glm::sin(thetaS);
			direction.z = glm::cos(thetaS);
			
			ray.origin = intersect + normal * EPSILON;
			ray.direction = glm::normalize(direction); //do i need to normalize this?

			// now color
			// Calculate intensity values
			float specularIntensity = (specularColor.x + specularColor.y + specularColor.z) / 3.0f;
			float diffuseIntensity = (diffuseColor.x + diffuseColor.y + diffuseColor.z) / 3.0f;

			float specularProbability = specularIntensity / (diffuseIntensity + specularIntensity);
			float diffuseProbability = diffuseIntensity / (diffuseIntensity + specularIntensity);

			if (specularProbability >= diffuseProbability) {
				color *= specularColor * (1.0f / specularProbability);
			}
			else {
				//diffuse won
				color *= diffuseColor * (1.0f / diffuseProbability);
			}
		}
		else {
			// perfect mirror
			//can just do the glm reflect and normal color shit
			ray.origin = intersect + normal * EPSILON;
			ray.direction = glm::reflect(intersect, normal);
			color *= specularColor;
		}
	}
	else {
		// diffuse only
		ray.origin = intersect + normal * EPSILON;
		ray.direction = calculateRandomDirectionInHemisphere(normal, rng);
		color *= m.color;
	}

	// TODO: Add refraction. Can something be diffuse, refractive, and reflective? (glass). how to do...
}
