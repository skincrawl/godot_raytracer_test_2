#[compute]
#version 450

#define MAX_BOUNCES 4


// This one loads in triangle data from Godot


struct Material {
    vec4 color;
    vec4 roughness;
    vec4 metallic;
};

struct Triangle {
    vec4 v0;
    vec4 v1;
    vec4 v2;
    Material material;
};

struct Sphere{
    vec3 center;
    float radius;
    Material material;
};

struct BVHNode {
    vec4 min;
    vec4 left;

    vec4 max;
    vec4 right;

    vec4 meta; // start, count, is_leaf
};

struct Hit {
    vec3 pos;
    vec3 normal;
    vec3 albedo;
    float roughness;
    float metallic;
};

// Triangles
layout(std430, binding = 0) buffer Triangles {
    Triangle tris[];
};

// BVH
layout(std430, binding = 1) buffer BVH {
    BVHNode bvh_nodes[];
};

layout(push_constant) uniform Params {
    int triangle_count;
} params;

layout(local_size_x = 8, local_size_y = 8) in;

// Output texture
layout(set = 0, binding = 2, rgba32f) uniform image2D dest_tex;

// Camera
layout(set = 0, binding = 3) uniform CameraData {
    vec4 cam_pos_fov; // xyz = position, w = fov_y (radians)
    vec3 cam_right;
    vec3 cam_up;
    vec3 cam_forward;
};

// Skybox texture
layout(set = 0, binding = 4) uniform sampler2D skybox_tex;


const float PI = 3.14159265359;

// vec3 sky_color = vec3(0.05, 0.05, 0.08);

// Directional light
// Points in the direction the photons are travelling (from the light toward the scene)
// So, down and slightly to the right and away from the camera
vec3 light_dir = normalize(vec3(0.4, -1.0, -0.2));

vec3 final_color = vec3(0.0, 0.0, 0.0);


bool intersect_aabb(vec3 ray_origin, vec3 ray_dir, vec3 box_min, vec3 box_max) {

    vec3 inv_dir = 1.0 / ray_dir;

    vec3 t0s = (box_min - ray_origin) * inv_dir;
    vec3 t1s = (box_max - ray_origin) * inv_dir;

    vec3 tmin = min(t0s, t1s);
    vec3 tmax = max(t0s, t1s);

    float t_enter = max(max(tmin.x, tmin.y), tmin.z);
    float t_exit  = min(min(tmax.x, tmax.y), tmax.z);

    return t_exit >= max(t_enter, 0.0);
}

bool intersect_triangle(

    vec3 ray_origin,
    vec3 ray_dir,
    Triangle tri,
    out float t
){
    vec3 v0 = tri.v0.xyz;
    vec3 v1 = tri.v1.xyz;
    vec3 v2 = tri.v2.xyz;

    vec3 edge1 = v1 - v0;
    vec3 edge2 = v2 - v0;

    vec3 pvec = cross(ray_dir, edge2);
    float det = dot(edge1, pvec);

    if (det > -0.000001)
        return false;

    float inv_det = 1.0 / det;

    vec3 tvec = ray_origin - v0;

    float u = dot(tvec, pvec) * inv_det;
    if (u < 0.0 || u > 1.0)
        return false;

    vec3 qvec = cross(tvec, edge1);

    float v = dot(ray_dir, qvec) * inv_det;
    if (v < 0.0 || u + v > 1.0)
        return false;

    t = dot(edge2, qvec) * inv_det;

    return t > 0.0;
}

bool intersect_sphere(

    vec3 ray_origin,
    vec3 ray_dir,
    Sphere s,
    out float t
){
    vec3 oc = ray_origin - s.center;
    float a = dot(ray_dir, ray_dir);
    float b = 2.0 * dot(oc, ray_dir);
    float c = dot(oc, oc) - s.radius * s.radius;

    float discriminant = b * b - 4.0 * a * c;
    if (discriminant < 0.0)
        return false;

    float sqrt_d = sqrt(discriminant);

    float t0 = (-b - sqrt_d) / (2.0 * a);
    float t1 = (-b + sqrt_d) / (2.0 * a);

    t = (t0 > 0.0) ? t0 : t1;

    return t > 0.0;
}

float rand(in vec2 co) {
    return fract(sin(dot(co, vec2(12.9898, 78.233))) * 43758.5453);
}

vec2 rand(in vec2 co, int a) {
    return co + vec2(float(a) * 37.0);
}

vec3 random_hemisphere(vec3 normal, vec2 seed) {
    float u = rand(seed);
    float v = rand(seed + 17.0);

    float phi = 2.0 * PI * u;
    float cos_theta = sqrt(1.0 - v);
    float sin_theta = sqrt(v);

    vec3 tangent = normalize(
        abs(normal.x) > 0.1
        ? cross(normal, vec3(0.0, 1.0, 0.0))
        : cross(normal, vec3(1.0, 0.0, 0.0))
    );
    vec3 bitangent = cross(normal, tangent);

    return normalize(
        tangent * cos(phi) * sin_theta +
        bitangent * sin(phi) * sin_theta +
        normal * cos_theta
    );
}

/* float Schlick_Fresnel(float cos_theta) {

}

vec3 Burley(float cos_theta_L, float cos_theta_V, float roughness) {

    float Fd90 = 0.5 + 2.0 * roughness * cos_theta_i * cos_theta_i;

    float FL = Schlick_Fresnel(cos_theta_L);
    float FV = Schlick_Fresnel(cos_theta_V);

    float Fd = (1.0 + (Fd90 - 1.0) * FL) * (1.0 + (Fd90 - 1.0) * FV);
}
*/

vec3 calculate_normal(Triangle tri) {
    vec3 v0 = tri.v0.xyz;
    vec3 v1 = tri.v1.xyz;
    vec3 v2 = tri.v2.xyz;
    vec3 normal = normalize(
        cross(v1 - v0, v2 - v0)
    );
    return normal;
}

bool intersect_scene(vec3 ray_origin, vec3 ray_dir, out Hit hit) {

    float t_closest = 1e20; // large number
    int hit_index = -1;
    vec3 color;

    bool was_hit = false;

    int stack[256];
    int stack_ptr = 0;

    stack[stack_ptr++] = 0; // root

    while(stack_ptr > 0) {

        int node_index = stack[--stack_ptr];
        BVHNode node = bvh_nodes[node_index];

        if (stack_ptr >= 60) {
            break;
        }

        if (node_index < 0 || node_index >= bvh_nodes.length()) {
            break;
        }

        if (!intersect_aabb(ray_origin, ray_dir, node.min.xyz, node.max.xyz)) {
            continue;
        }

        int start = int(node.meta.x);
        int count = int(node.meta.y);
        int is_leaf = int(node.meta.z);
        if (is_leaf == 1) { // Leaf node

            // final_color = vec3(0.0, 1.0, 0.0);

            for (int i = 0; i < count; i++) {
                Triangle tri = tris[start + i];
                float t = 0.0;

                if (intersect_triangle(ray_origin, ray_dir, tri, t)) {
                    was_hit = true;
                    if (t < t_closest){
                        t_closest = t;
                        hit_index = start + i;
                    }
                }
            }

        } else {
            if (stack_ptr < 62) {
                int left = int(node.left.x);
                int right = int(node.right.x);
                if (left >= 0) stack[stack_ptr++] = left;
                if (left >= 0) stack[stack_ptr++] = right;
            }
        }
    }

    if(hit_index != -1){

        Triangle tri = tris[hit_index];

        hit.normal = calculate_normal(tri);
        if (dot(hit.normal, ray_dir) > 0.0)
            hit.normal = -hit.normal;

        hit.pos = ray_origin + ray_dir * t_closest;
        hit.albedo = tri.material.color.xyz;
        // hit.roughness = 0.0;
        // hit.metallic = 1.0;
        hit.roughness = tri.material.roughness.x;
        hit.metallic = tri.material.metallic.x;

        return true;
    } else {
        return false;
    }
}


void main(){

    // Setting up coordinates and stuff
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    ivec2 size = imageSize(dest_tex);

    if(pixel.x >= size.x || pixel.y >= size.y)
        return;

    float aspect = float(size.x) / float(size.y);

    // UV in [-1, 1]
    vec2 uv = (vec2(pixel) + 0.5) / vec2(size);
    uv = uv * 2.0 - 1.0;
    uv.y *= -1.0;

    float fov_y = cam_pos_fov.w;
    float focal = 1.0 / tan(fov_y * 0.5);

    // Setting up the initial ray
    vec3 ray_origin = cam_pos_fov.xyz;
    vec3 ray_dir =
    cam_forward +
    cam_right * uv.x * aspect +
    cam_up * uv.y;
    ray_dir = normalize(ray_dir);
    vec3 light_color = vec3(1.0);

    // Let's get started with the ray tracing!

    uint bounces = 0;
    vec3 throughput = vec3(1.0);
    vec3 final_color = vec3(0.0);
    Hit hit;

    for (int bounce = 0; bounce < MAX_BOUNCES; bounce++) {

        if (!intersect_scene(ray_origin, ray_dir, hit)) {
            vec3 sky_color;
            float u = 0.5 + atan(ray_dir.x, ray_dir.z) / (2.0 * PI);
            float v = 0.5 - asin(ray_dir.y) / PI;
            sky_color = texture(skybox_tex, vec2(u, v)).rgb;
            final_color += throughput * sky_color;
            // final_color += throughput * vec3(0.0, 1.0, 0.0);
            break;
        }

        vec3 albedo = hit.albedo;
        vec3 normal = hit.normal;
        float roughness = hit.roughness;
        float metallic = hit.metallic;

        vec3 shadow_origin = hit.pos + normal * 0.001;
        Hit shadow_hit;

        vec3 L = normalize(-light_dir); // direction FROM surface TO light
        bool in_shadow = intersect_scene(shadow_origin, L, shadow_hit);

        float cos_theta = max(dot(normal, -ray_dir), 0.0);

        if (!in_shadow) {

            // direct lighting
            float diffuse = cos_theta;
            final_color += throughput * albedo * diffuse * light_color;
            // final_color = albedo;
            // final_color = normal * 0.5 + 0.5;
            // final_color = abs(normal);
        } // else {
        // final_color = vec3(0.0, 1.0, 0.0);
        // }

        // prepare next bounce
        ray_origin = hit.pos + normal * 0.001;

        vec2 seed = rand(pixel, bounce);
        vec3 diffuse_dir = random_hemisphere(normal, seed);
        vec3 reflect_dir = reflect(ray_dir, normal);

        // vec3 bounce_dir = normalize(
        //     mix(reflect_dir, diffuse_dir, roughness)
        // );

        vec3 F0 = mix(vec3(0.04), albedo, metallic); // Dielectric default light amount
        vec3 F = F0 + (1.0 - F0) * pow((1.0 - cos_theta), 5.0);
        vec3 spec_color = mix(F, albedo, metallic);

        float spec_prob = mix(1.0 - roughness, 1.0, length(F));
        bool is_specular = (rand(seed) < spec_prob);
        vec3 albedo_out;

        if (is_specular) {
            ray_dir = reflect_dir;
            throughput *= F;
        } else {
            ray_dir = diffuse_dir;
            throughput *= albedo;
        }

        // throughput *= 0.5;

        // color += contribution * calculate_contribution(ray_dir);
    }

    imageStore(dest_tex, pixel, vec4(final_color, 1.0));
}
