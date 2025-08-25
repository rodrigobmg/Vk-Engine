#ifndef SKINNING_GLSL
#define SKINNING_GLSL

void ApplySkinning(
    uint skinning_matrix_offset,
    int4 joint_ids, float3 joint_weights,
    inout float3 model_space_position,
    inout float3 model_space_normal,
    inout float3 model_space_tangent
) {
    float3 original_position = model_space_position;
    float3 original_normal = model_space_normal;
    float3 original_tangent = model_space_tangent;

    if (joint_ids[0] != -1) {
        model_space_position = float3(0);
        model_space_normal = float3(0);
        model_space_tangent = float3(0);

        float4 weights = float4(joint_weights, 1 - (joint_weights.x + joint_weights.y + joint_weights.z));

        for (int i = 0; i < 4; i += 1) {
            float4x4 skinning_matrix = u_skinning_matrices[skinning_matrix_offset + joint_ids[i]];

            float3 pose_position = (skinning_matrix * float4(original_position, 1)).xyz;
            model_space_position += pose_position * weights[i];

            float3 pose_normal = (skinning_matrix * float4(original_normal, 0)).xyz;
            model_space_normal += pose_normal * weights[i];

            float3 pose_tangent = (skinning_matrix * float4(original_tangent, 0)).xyz;
            model_space_tangent += pose_tangent * weights[i];
        }
    }
}

// void ApplySkinning(
//     uint skinning_matrix_offset,
//     int4 joint_ids, float3 joint_weights,
//     inout float3 model_space_position
// ) {
//     float3 original_position = model_space_position;

//     if (joint_ids[0] != -1) {
//         model_space_position = float3(0);

//         float4 weights = float4(joint_weights, 1 - (joint_weights.x + joint_weights.y + joint_weights.z));

//         for (int i = 0; i < 4; i += 1) {
//             float4x4 skinning_matrix = u_skinning_matrices[skinning_matrix_offset + joint_ids[i]];

//             float3 pose_position = (skinning_matrix * float4(original_position, 1)).xyz;
//             model_space_position += pose_position * weights[i];
//         }
//     }
// }

#endif
