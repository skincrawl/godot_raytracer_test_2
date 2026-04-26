#[compute]
#version 450

#define MAX_BOUNCES 4


layout(local_size_x = 8, local_size_y = 8) in;

// Output texture
layout(set = 0, binding = 0, rgba32f) uniform image2D dest_tex;

// Camera
layout(set = 0, binding = 1) uniform CameraData {
    vec4 cam_pos_fov; // xyz = position, w = fov_y (radians)
    vec3 cam_right;
    vec3 cam_up;
    vec3 cam_forward;
};

// Skybox texture
layout(set = 0, binding = 2) uniform sampler2D skybox_tex;


const float PI = 3.14159265359;


struct Material {
    vec3 color;
};

struct Triangle {
    vec3 v0;
    vec3 v1;
    vec3 v2;
    Material material;
};

struct Hit {
    vec3 pos;
    vec3 normal;
    vec3 albedo;
};

Triangle tris[14];

// vec3 sky_color = vec3(0.05, 0.05, 0.08);

// Directional light
// Points in the direction the photons are travelling (from the light toward the scene)
// So, down and slightly to the right and away from the camera
vec3 light_dir = normalize(vec3(0.1, 1.0, 0.1));

void setup_scene() {

    // Materials
    Material floor_material = Material(vec3(0.8, 0.8, 0.8));
    Material cube_material  = Material(vec3(0.8, 0.2, 0.4));

    // Floor quad made of two triangles

    tris[0] = Triangle(
        vec3( 4.0,  2.0, 10.0),
        vec3(-4.0,  2.0, 2.0),
        vec3(-4.0,  2.0, 10.0),
        floor_material
    );

    tris[1] = Triangle(
        vec3( 4.0,  2.0, 10.0),
        vec3( 4.0,  2.0, 2.0),
        vec3(-4.0,  2.0, 2.0),
        floor_material
    );

    // Cube made of twelve triangles

    // Vertices

    // Bottom
    vec3 lbf = vec3(-0.5, 2.0, 3.5);       // Left,  bottom, front
    vec3 lbb = vec3(-0.5, 2.0, 4.5);       // Left,  bottom, back
    vec3 rbb = vec3( 0.5, 2.0, 4.5);       // Right, bottom, back
    vec3 rbf = vec3( 0.5, 2.0, 3.5);       // Right, bottom, front

    // Top
    vec3 rtb = vec3( 0.5, 1.0, 4.5);       // Right, top, back
    vec3 ltb = vec3(-0.5, 1.0, 4.5);       // Left,  top, back
    vec3 ltf = vec3(-0.5, 1.0, 3.5);       // Left,  top, front
    vec3 rtf = vec3( 0.5, 1.0, 3.5);       // Right, top, front


    // Bottom
    tris[2] = Triangle(lbf, lbb, rbb, cube_material);
    tris[3] = Triangle(lbf, rbb, rbf, cube_material);

    // Back
    tris[4] = Triangle(rbb, lbb, ltb, cube_material);
    tris[5] = Triangle(rbb, ltb, rtb, cube_material);

    // Left
    tris[6] = Triangle(ltf, ltb, lbb, cube_material);
    tris[7] = Triangle(ltf, lbb, lbf, cube_material);

    // Right
    tris[8] = Triangle(rtb, rtf, rbf, cube_material);
    tris[9] = Triangle(rtb, rbf, rbb, cube_material);

    // Front
    tris[10] = Triangle(rtf, ltf, lbf, cube_material);
    tris[11] = Triangle(rtf, lbf, rbf, cube_material);

    // Top
    tris[12] = Triangle(rtb, ltb, ltf, cube_material);
    tris[13] = Triangle(rtb, ltf, rtf, cube_material);
}


bool intersect_triangle(

    vec3 ray_origin,
    vec3 ray_dir,
    Triangle tri,
    out float t
){
    vec3 edge1 = tri.v1 - tri.v0;
    vec3 edge2 = tri.v2 - tri.v0;

    vec3 pvec = cross(ray_dir, edge2);
    float det = dot(edge1, pvec);

    if (abs(det) < 0.000001)
        return false;

    float inv_det = 1.0 / det;

    vec3 tvec = ray_origin - tri.v0;

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

vec3 calculate_normal(Triangle tri) {
    vec3 normal = normalize(
        cross(tri.v1 - tri.v0, tri.v2 - tri.v0)
    );
    return normal;
}

bool intersect_scene(vec3 ray_origin, vec3 ray_dir, out Hit hit) {

    float t_closest = 1e20; // large number
    int hit_index = -1;
    vec3 color;

    // int n // length of the tris array. Is there a way to calculate it? I guess I should only do that once though
    int n_tris = 14;

    for(int i = 0; i < n_tris; i++){
        float t = 0.0;
        if(intersect_triangle(ray_origin, ray_dir, tris[i], t)){
            if (t < t_closest){
                t_closest = t;
                hit_index = i;
            }
        }
    }

    if(hit_index != -1){

        Triangle tri = tris[hit_index];

        hit.normal = calculate_normal(tri);
        if (dot(hit.normal, ray_dir) > 0.0)
            hit.normal = -hit.normal;

        hit.pos = ray_origin + ray_dir * t_closest;
        hit.albedo = tri.material.color;

        return true;
    } else {
        return false;
    }
}


vec3 calculate_contribution(vec3 _ray_origin, out vec3 _ray_dir) {

    float t_closest = 1e20; // large number
    int hit_index = -1;
    vec3 color;

    for(int i = 0; i < 14; i++){
        float t = 0.0;
        if(intersect_triangle(_ray_origin, _ray_dir, tris[i], t)){
            if (t < t_closest){
                t_closest = t;
                hit_index = i;
            }
        }
    }

    if(hit_index != -1){

        Triangle tri = tris[hit_index];

        vec3 normal = calculate_normal(tri);

        vec3 hit_pos = _ray_origin + _ray_dir * t_closest;


        bool in_shadow = false;

        for (int i = 0; i < 14; i++){
            float t_shadow;

            if (intersect_triangle(hit_pos + normal * 0.001, -light_dir, tris[i], t_shadow)) {
                // ignore self
                if (i == hit_index) continue;

                in_shadow = true;
                break;
            }
        }

        vec3 ray_reflect_dir = reflect(_ray_dir, normal);
        _ray_dir = ray_reflect_dir;

        float diffuse = max(dot(normal, -light_dir), 0.0);

        if (in_shadow) {
            diffuse *= 0.0; // hard shadow
        }

        color = tris[hit_index].material.color * diffuse;
        // color = normal * 0.5 + 0.5; // map -1..1 to 0..1
        // color = abs(normal);
        // color = vec3(float(hit_index) / 14.0);
        // color = vec3(1.0, 1.0, 1.0) * diffuse;

    } else {
        vec3 sky_color;
        color = sky_color;
    }

    return color;
}

void main(){

    setup_scene();

    // Setting up coordinates and stuff
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    ivec2 size = imageSize(dest_tex);

    if(pixel.x >= size.x || pixel.y >= size.y)
        return;

    float aspect = float(size.x) / float(size.y);

    // UV in [-1, 1]
    vec2 uv = (vec2(pixel) + 0.5) / vec2(size);
    uv = uv * 2.0 - 1.0;

    float fov_y = cam_pos_fov.w;
    float focal = 1.0 / tan(fov_y * 0.5);

    // float half_height = tan(fov_y * 0.5);
    // float half_width = half_height * aspect;

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

    for (int i = 0; i < MAX_BOUNCES; i++) {

        if (!intersect_scene(ray_origin, ray_dir, hit)) {
            vec3 sky_color;
            float u = 0.5 + atan(ray_dir.x, ray_dir.z) / (2.0 * PI);
            float v = 0.5 + asin(ray_dir.y) / PI;
            sky_color = texture(skybox_tex, vec2(u, v)).rgb;
            final_color += throughput * sky_color;
            // final_color += throughput * vec3(0.0, 1.0, 0.0);
            break;
        }

        vec3 normal = hit.normal;

        // direct lighting
        float diffuse = max(dot(normal, -light_dir), 0.0);
        final_color += throughput * hit.albedo * diffuse * light_color;
        // final_color = abs(normal);

        // prepare next bounce
        ray_origin = hit.pos + normal * 0.001;
        ray_dir = reflect(ray_dir, normal);

        throughput *= hit.albedo * 0.5;

        // color += contribution * calculate_contribution(ray_dir);
    }

    imageStore(dest_tex, pixel, vec4(final_color, 1.0));
}
