// Abstraction layer on top of Vulkan, with defaults such that most use cases have much less code to write
// Sometimes, these defaults just mean that there is less code but don't impact performance (e.g. pipeline
// creation) but sometimes these defaults take into account the worst-case scenario (e.g. default attachment
// load/store is not optimal in many cases at all, barriers have overloads that take no argument but sync on
// all commands)

// How to use VkMemAlloc for most use cases:
// https://gpuopen-librariesandsdks.github.io/VulkanMemoryAllocator/html/usage_patterns.html
// Synchronization in Vulkan:
// https://themaister.net/blog/2019/08/14/yet-another-blog-explaining-vulkan-synchronization/
// Writing an efficient Vulkan renderer:
// https://zeux.io/2020/02/27/writing-an-efficient-vulkan-renderer/

Log_Vulkan :: Log_Section.{name="Graphics/Vulkan"};

Gfx_Max_Color_Attachments :: 8;
Gfx_Num_Frames_In_Flight :: 2;
Gfx_Viewport_Origin_Bottom_Left :: false;

g_gfx_context : GfxContext;
g_vk_alloc_callbacks : *VkAllocationCallbacks;

GfxContext :: struct {
    window : *SDL_Window;
    instance : VkInstance;
    debug_messenger : VkDebugUtilsMessengerEXT;
    surface : VkSurfaceKHR;
    physical_device : VkPhysicalDevice;
    device : VkDevice;
    general_purpose_queue_index : u32;
    present_queue_index : u32;
    general_purpose_queue : VkQueue;
    present_queue : VkQueue;
    swapchain : VkSwapchainKHR;
    swapchain_format : GfxPixelFormat;
    swapchain_extent : VkExtent2D;
    swapchain_textures : []GfxTexture;
    frame_command_pools : []GfxCommandPool;
    swapchain_image_acquired_semaphores : []VkSemaphore;
    swapchain_image_ready_for_present_semaphores : []VkSemaphore;
    frame_in_flight_fences : []VkFence;
    frame_in_flight : int;
    frame_index : int;
    frame_swapchain_image_index : u32;
    allocation_callbacks : VkAllocationCallbacks;
    allocator : VmaAllocator;
    limits : GfxLimits;

    texture_view_collectors : [Gfx_Num_Frames_In_Flight]GfxGarbageCollector(GfxTexture, DestroyGfxTextureView);
    texture_collectors : [Gfx_Num_Frames_In_Flight]GfxGarbageCollector(GfxTexture);
    sampler_collectors : [Gfx_Num_Frames_In_Flight]GfxGarbageCollector(GfxSampler);
    buffer_collectors : [Gfx_Num_Frames_In_Flight]GfxGarbageCollector(GfxBuffer);

    command_buffers_to_submit : [..]VkCommandBuffer;

    vkSetDebugUtilsObjectNameEXT : PFN_vkSetDebugUtilsObjectNameEXT;
    vkCmdBeginDebugUtilsLabelEXT : PFN_vkCmdBeginDebugUtilsLabelEXT;
    vkCmdEndDebugUtilsLabelEXT : PFN_vkCmdEndDebugUtilsLabelEXT;
    vkQueueBeginDebugUtilsLabelEXT : PFN_vkQueueBeginDebugUtilsLabelEXT;
    vkQueueEndDebugUtilsLabelEXT : PFN_vkQueueEndDebugUtilsLabelEXT;
}

// Tool to defer destroying objects after the last frame they were used is finished processing on the GPU
GfxGarbageCollector :: struct($T : Type, destroy_func : #type (*T) = null) {
    garbage : [..]T;
}

AddGarbage :: (collector : *GfxGarbageCollector, garbage : collector.T) {
    ArrayPush(*collector.garbage, garbage);
}

DestroyGfxGarbageCollector :: (collector : *GfxGarbageCollector) {
    CollectGarbage(collector);
    ArrayFree(*collector.garbage);
}

CollectGarbage :: (collector : *GfxGarbageCollector) {
    #if collector.destroy_func {
        Destroy :: collector.destroy_func;
    } else {
        Destroy :: #insert #run TPrint("Destroy%;", collector.T);
    }

    for * collector.garbage {
        Destroy(it);
    }

    ArrayClear(*collector.garbage);
}

GfxLimits :: struct {
    max_texture_1d_dimension : u32;
    max_texture_2d_dimension : u32;
    max_texture_3d_dimension : u32;
    max_texture_cube_dimension : u32;
    max_texture_array_layers : u32;
    max_memory_allocation_count : u32;
    max_sampler_allocation_count : u32;
    max_uniform_buffer_size : u32;
    max_storage_buffer_size : u32;
    uniform_buffer_offset_alignment : u32;
    storage_buffer_offset_alignment : u32;
}

MakeGfxLimits :: inline (limits : VkPhysicalDeviceLimits) -> GfxLimits {
    result : GfxLimits;
    result.max_texture_1d_dimension = limits.maxImageDimension1D;
    result.max_texture_2d_dimension = limits.maxImageDimension2D;
    result.max_texture_3d_dimension = limits.maxImageDimension3D;
    result.max_texture_cube_dimension = limits.maxImageDimensionCube;
    result.max_texture_array_layers = limits.maxImageArrayLayers;
    result.max_memory_allocation_count = limits.maxMemoryAllocationCount;
    result.max_sampler_allocation_count = limits.maxSamplerAllocationCount;
    result.max_uniform_buffer_size = limits.maxUniformBufferRange;
    result.max_storage_buffer_size = limits.maxStorageBufferRange;
    result.uniform_buffer_offset_alignment = xx limits.minUniformBufferOffsetAlignment;
    result.storage_buffer_offset_alignment = xx limits.minStorageBufferOffsetAlignment;

    return result;
}

GetGfxLimits :: inline () -> GfxLimits {
    return g_gfx_context.limits;
}

BeginFrame :: () {
    ctx := *g_gfx_context;

    ctx.frame_in_flight += 1;
    ctx.frame_in_flight %= Gfx_Num_Frames_In_Flight;
    ctx.frame_index += 1;

    wait_result := vkWaitForFences(ctx.device, 1, *ctx.frame_in_flight_fences[ctx.frame_in_flight], VK_TRUE, Frame_Max_Wait);
    Assert(wait_result == .SUCCESS, "vkWaitForFences failed: %", wait_result);

    while true {
        acquire_result := vkAcquireNextImageKHR(ctx.device, ctx.swapchain, Frame_Max_Wait, ctx.swapchain_image_acquired_semaphores[ctx.frame_in_flight], null, *ctx.frame_swapchain_image_index);

        // If we get SUBOPTIMAL_KHR then semaphore has been signaled so we cannot
        // ask again with the same semaphore.
        // Continue rendering as normal, we'll recreate the swapchain later
        if acquire_result == .ERROR_OUT_OF_DATE_KHR {
            RecreateSwapchain();
        } else {
            Assert(acquire_result == .SUCCESS || acquire_result == .SUBOPTIMAL_KHR, "vkAcquireNextImageKHR failed: %", acquire_result);
            break;
        }
    }

    vkResetFences(ctx.device, 1, *ctx.frame_in_flight_fences[ctx.frame_in_flight]);

    cmd_pool := *ctx.frame_command_pools[ctx.frame_in_flight];
    ResetGfxCommandPool(cmd_pool);

    BeginGfxDebugMarker(TPrint("Frame %", ctx.frame_index));

    CollectGarbage(*ctx.texture_view_collectors[ctx.frame_in_flight]);
    CollectGarbage(*ctx.texture_collectors[ctx.frame_in_flight]);
    CollectGarbage(*ctx.sampler_collectors[ctx.frame_in_flight]);
    CollectGarbage(*ctx.buffer_collectors[ctx.frame_in_flight]);
}

SubmitFrame :: () {
    ctx := *g_gfx_context;

    EndGfxDebugMarker();

    submit_stage_mask := VkPipelineStageFlags.COLOR_ATTACHMENT_OUTPUT_BIT;
    submit_info : VkSubmitInfo;
    submit_info.waitSemaphoreCount = 1;
    submit_info.pWaitSemaphores = *ctx.swapchain_image_acquired_semaphores[ctx.frame_in_flight];
    submit_info.pWaitDstStageMask = *submit_stage_mask;
    submit_info.signalSemaphoreCount = 1;
    submit_info.pSignalSemaphores = *ctx.swapchain_image_ready_for_present_semaphores[ctx.frame_swapchain_image_index];
    submit_info.commandBufferCount = xx ctx.command_buffers_to_submit.count;
    submit_info.pCommandBuffers = ctx.command_buffers_to_submit.data;
    vkQueueSubmit(ctx.general_purpose_queue, 1, *submit_info, ctx.frame_in_flight_fences[ctx.frame_in_flight]);

    ArrayClear(*ctx.command_buffers_to_submit);

    present_info : VkPresentInfoKHR;
    present_info.swapchainCount = 1;
    present_info.pSwapchains = *ctx.swapchain;
    present_info.waitSemaphoreCount = 1;
    present_info.pWaitSemaphores = *ctx.swapchain_image_ready_for_present_semaphores[ctx.frame_swapchain_image_index];
    present_info.pImageIndices = *ctx.frame_swapchain_image_index;
    present_result := vkQueuePresentKHR(ctx.present_queue, *present_info);
    if present_result == .ERROR_OUT_OF_DATE_KHR || present_result == .SUBOPTIMAL_KHR {
        RecreateSwapchain();
    } else {
        Assert(present_result == .SUCCESS, "Failed to present swapchain image");
    }
}

WaitForGPUIdle :: () {
    vkDeviceWaitIdle(g_gfx_context.device);
}

GfxCommandPool :: struct {
    pool : VkCommandPool;
    free_cmd_buffers : [..]GfxCommandBuffer;
    used_cmd_buffers : [..]GfxCommandBuffer;
}

IsNull :: inline (pool : *GfxCommandPool) -> bool {
    return pool == null || pool.pool == VK_NULL_HANDLE;
}

CreateGfxCommandPool :: (name : string) -> GfxCommandPool {
    ctx := *g_gfx_context;

    pool_info : VkCommandPoolCreateInfo;
    pool_info.queueFamilyIndex = ctx.general_purpose_queue_index;

    pool : VkCommandPool;
    if vkCreateCommandPool(ctx.device, *pool_info, g_vk_alloc_callbacks, *pool) != .SUCCESS {
        return .{};
    }

    SetDebugName(pool, TPrint("Command Pool '%'", name));

    return .{pool=pool};
}

DestroyGfxCommandPool :: (pool : *GfxCommandPool) {
    ArrayFree(*pool.free_cmd_buffers);
    ArrayFree(*pool.used_cmd_buffers);

    vkDestroyCommandPool(g_gfx_context.device, pool.pool, g_vk_alloc_callbacks);
    pool.* = .{};
}

ResetGfxCommandPool :: (pool : *GfxCommandPool) {
    for pool.used_cmd_buffers {
        ArrayPush(*pool.free_cmd_buffers, it);
    }

    ArrayClear(*pool.used_cmd_buffers);

    vkResetCommandPool(g_gfx_context.device, pool.pool, 0);
}

GfxCommandBuffer :: struct {
    cmd_buffer : VkCommandBuffer;
}

IsNull :: inline (cmd_buffer : *GfxCommandBuffer) -> bool {
    return cmd_buffer == null || cmd_buffer.cmd_buffer == VK_NULL_HANDLE;
}

CreateGfxCommandBuffer :: (name : string) -> GfxCommandBuffer {
    ctx := *g_gfx_context;
    pool := *ctx.frame_command_pools[ctx.frame_in_flight];

    if pool.free_cmd_buffers.count > 0 {
        cmd_buffer := pool.free_cmd_buffers[pool.free_cmd_buffers.count - 1];
        ArrayPop(*pool.free_cmd_buffers);
        ArrayPush(*pool.used_cmd_buffers, cmd_buffer);

        begin_info : VkCommandBufferBeginInfo;
        begin_info.flags = .ONE_TIME_SUBMIT_BIT;
        vkBeginCommandBuffer(cmd_buffer.cmd_buffer, *begin_info);

        SetDebugName(cmd_buffer.cmd_buffer, TPrint("Command Buffer '%'", name));

        return cmd_buffer;
    }

    create_info : VkCommandBufferAllocateInfo;
    create_info.commandPool = pool.pool;
    create_info.level = .PRIMARY;
    create_info.commandBufferCount = 1;

    cmd_buffer : VkCommandBuffer;
    if vkAllocateCommandBuffers(ctx.device, *create_info, *cmd_buffer) != .SUCCESS {
        return .{};
    }

    begin_info : VkCommandBufferBeginInfo;
    begin_info.flags = .ONE_TIME_SUBMIT_BIT;
    vkBeginCommandBuffer(cmd_buffer, *begin_info);

    SetDebugName(cmd_buffer, TPrint("Command Buffer '%'", name));

    result := GfxCommandBuffer.{cmd_buffer=cmd_buffer};

    ArrayPush(*pool.used_cmd_buffers, result);

    return result;
}

SubmitGfxCommandBuffer :: (cmd_buffer : GfxCommandBuffer) {
    ctx := *g_gfx_context;

    vkEndCommandBuffer(cmd_buffer.cmd_buffer);
    ArrayPush(*ctx.command_buffers_to_submit, cmd_buffer.cmd_buffer);
}

GfxShader :: struct {
    module : VkShaderModule;
}

IsNull :: inline (shader : *GfxShader) -> bool {
    return shader == null || shader.module == VK_NULL_HANDLE;
}

// @Todo: integrate libshaderc instead of launching a child process
LoadGfxShader :: (name : string, extra_compiler_args : []string = .[], dependencies : *[..]string = null) -> GfxShader {
    stage := ifx StringEndsWith(name, ".vert")
        then "vert"
        else ifx StringEndsWith(name, ".frag")
        then "frag"
        else ifx StringEndsWith(name, ".comp")
        then "comp";

    if !stage {
        LogError("Could not detect shader stage for shader '%'", name);
        return .{};
    }

    stage_define := ifx stage == "vert"
        then "SHADER_STAGE_VERTEX"
        else ifx stage == "frag"
        then "SHADER_STAGE_FRAGMENT"
        else ifx stage == "comp"
        then "SHADER_STAGE_COMPUTE";

    filename := TPrint("Shaders/%.glsl", name);
    output_filename := TPrint("Shaders/%.spv", name);

    args : [..]string;
    args.allocator = Temp;
    ArrayPush(*args, "glslc");
    ArrayPush(*args, "-g");
    ArrayPush(*args, "-std=460");
    ArrayPush(*args, "--target-env=vulkan1.3");
    ArrayPush(*args, TPrint("-fshader-stage=%", stage));
    ArrayPush(*args, TPrint("-D%", stage_define));
    ArrayPushMultiple(*args, extra_compiler_args);
    ArrayPush(*args, filename);

    ArrayPush(*args, TPrint("-o%", output_filename));

    result, stdout, stderr := run_command(..args, capture_and_return_output=true);

    defer {
        Free(stdout.data);
        Free(stderr.data);
    }

    if result.exit_code != 0 {
        LogError("Could not compile shader '%':\n%", filename, stderr);
        return .{};
    }

    if dependencies {
        ArrayPop(*args);
        ArrayPush(*args, "-M");

        _, stdout, stderr := run_command(..args, capture_and_return_output=true);
        defer Free(stdout.data);
        defer Free(stderr.data);

        dependencies_str := stdout;
        colon_index := find_index_from_left(dependencies_str, ":");
        if colon_index >= 0 {
            dependencies_str = StringAdvance(dependencies_str, colon_index + 1);
        }

        splits := split(dependencies_str, " " ,, Temp);
        for splits {
            if it.count <= 0 {
                continue;
            }

            dep := trim(it);
            dep = get_absolute_path(dep ,, Temp);
            path_overwrite_separators(dep, #char "/");

            ArrayPush(dependencies, StringClone(dep));
        }
    }

    code, ok := read_entire_file(output_filename);
    if !ok {
        LogError("Could not read file '%'", output_filename);
        return .{};
    }

    defer Free(code.data);

    create_info : VkShaderModuleCreateInfo;
    create_info.sType = .SHADER_MODULE_CREATE_INFO;
    create_info.codeSize = xx code.count;
    create_info.pCode = cast(*u32, code.data);

    module : VkShaderModule;
    if vkCreateShaderModule(g_gfx_context.device, *create_info, g_vk_alloc_callbacks, *module) != .SUCCESS {
        LogError("Could not create shader module");
        return .{};
    }

    SetDebugName(module, TPrint("Shader '%'", name));

    return .{module=module};
}

DestroyGfxShader :: (shader : *GfxShader) {
    vkDestroyShaderModule(g_gfx_context.device, shader.module, g_vk_alloc_callbacks);
    shader.* = .{};
}

// In our abstraction layer, we rename descriptor to shader binding. We allow ourselves to rename things because
// the idea is not necessarily to create a Vulkan-centric API, we might want to support Metal and D3D12 (although
// D3D12 also uses the term "descriptor").
// Descriptor is a confusing name, you absolutely cannot know what this term refers to unless you've read
// documentation, and even then it's still confusing how it all comes together in the rendering code.
// Additionally, in Metal and D3D12, a "descriptor" encapsulates all the parameters needed to create an object
// (e.g. MTLTextureDescriptor, D3D12_RESOURCE_DESC). This is basically the CreateInfo structures in Vulkan.
// We inherited that terminology, although we use the abbreviation "desc" to actually mean "description" more than
// "descriptor" because I think that term is more accurate. Hence we prefer the term binding set.

// While high end graphics cards can support 32 bound descriptor sets, a lot of lower end graphics devices only
// support a maximum of 4 different descriptors sets.
// A common strategy is to manage these different descriptor sets by binding frequency.
// * set 0 is bound once at the beginning of the frame and contains global per frame data
// * set 1 is bound at the beginning of a render pass and contains per render pass data
// * set 2 is bound per draw call and contains information about the objects we are rendering such as the
// transform matrices and material textures and parameters
// Sets bindings go from least often changed to most often changed, because when binding a new graphics pipeline
// currently bound descriptor sets from 0 to N are not unbound if they are compatible with the descriptor set
// layout of the new pipeline, set N + 1 being the first incompatible set (even compatible sets after N + 1 are
// unbound). See https://docs.vulkan.org/spec/latest/chapters/descriptorsets.html#descriptorsets-compatibility

GfxShaderStageFlags :: enum_flags u8 {
    Vertex;
    Fragment;
    Compute;
}

MakeVkShaderStageFlags :: inline (stages : GfxShaderStageFlags) -> VkShaderStageFlags {
    result : VkShaderStageFlags;
    if stages & .Vertex {
        result |= .VERTEX_BIT;
    }
    if stages & .Fragment {
        result |= .FRAGMENT_BIT;
    }
    if stages & .Compute {
        result |= .COMPUTE_BIT;
    }

    return result;
}

GfxBindingType :: enum u8 {
    UniformBuffer;
    StorageBuffer;
    Texture;
    Sampler;
    CombinedTextureSampler;
    StorageImage;
}

GetGfxBindingType :: (type : *Type_Info) -> GfxBindingType {
    if type == {
    case type_info(GfxBindingUniformBuffer);
        return .UniformBuffer;
    case type_info(GfxBindingStorageBuffer);
        return .StorageBuffer;
    case type_info(GfxBindingTexture);
        return .Texture;
    case type_info(GfxBindingSampler);
        return .Sampler;
    case type_info(GfxBindingCombinedTextureSampler);
        return .CombinedTextureSampler;
    case type_info(GfxBindingStorageImage);
        return .StorageImage;
    }

    Panic("Invalid shader param type %", get_type(type));
    return xx 0;
}

MakeVkDescriptorType :: inline (type : GfxBindingType) -> VkDescriptorType {
    if #complete type == {
    case .UniformBuffer;          return .UNIFORM_BUFFER;
    case .StorageBuffer;          return .STORAGE_BUFFER;
    case .Texture;                return .SAMPLED_IMAGE;
    case .Sampler;                return .SAMPLER;
    case .CombinedTextureSampler; return .COMBINED_IMAGE_SAMPLER;
    case .StorageImage;           return .STORAGE_IMAGE;
    }
}

GfxBindingFlags :: enum_flags u8 {
    AllowNull;
}

MakeVkDescriptorBindingFlags :: inline (flags : GfxBindingFlags) -> VkDescriptorBindingFlags {
    result : VkDescriptorBindingFlags;
    if flags & .AllowNull {
        result |= .PARTIALLY_BOUND_BIT;
    }

    return result;
}

GfxBindingDesc :: struct {
    binding : u32;
    type : GfxBindingType;
    stage_flags : GfxShaderStageFlags;
    num_array_layers : u32 = 1;
    flags : GfxBindingFlags;
}

GfxBindingSetLayoutDesc :: struct {
    bindings : []GfxBindingDesc;
}

GfxBindingSetLayout :: struct {
    layout : VkDescriptorSetLayout;
    desc : GfxBindingSetLayoutDesc;
}

IsNull :: inline (layout : *GfxBindingSetLayout) -> bool {
    return layout == null || layout.layout == VK_NULL_HANDLE;
}

CreateGfxBindingSetLayout :: (name : string, desc : GfxBindingSetLayoutDesc) -> GfxBindingSetLayout {
    LogSectionScope(*Log_Vulkan);

    create_info : VkDescriptorSetLayoutCreateInfo;
    create_info.bindingCount = xx desc.bindings.count;
    create_info.pBindings = Alloc(VkDescriptorSetLayoutBinding, desc.bindings.count, initialize=true ,, Temp);

    binding_flags : VkDescriptorSetLayoutBindingFlagsCreateInfo;
    binding_flags.bindingCount = xx desc.bindings.count;
    binding_flags.pBindingFlags = Alloc(VkDescriptorBindingFlags, desc.bindings.count, initialize=true ,, Temp);

    create_info.pNext = *binding_flags;

    for desc.bindings {
        binding := *create_info.pBindings[it_index];
        binding.binding = it.binding;
        binding.descriptorType = MakeVkDescriptorType(it.type);
        binding.descriptorCount = it.num_array_layers;
        binding.stageFlags = MakeVkShaderStageFlags(it.stage_flags);

        binding_flags.pBindingFlags[it_index] = MakeVkDescriptorBindingFlags(it.flags);
    }

    layout : VkDescriptorSetLayout;
    if vkCreateDescriptorSetLayout(g_gfx_context.device, *create_info, g_vk_alloc_callbacks, *layout) != .SUCCESS {
        return .{};
    }

    SetDebugName(layout, TPrint("Descriptor Set Layout '%'", name));

    copied_desc := desc;
    copied_desc.bindings = ArrayClone(desc.bindings);

    return .{layout=layout, desc=copied_desc};
}

DestroyGfxBindingSetLayout :: (layout : *GfxBindingSetLayout) {
    LogSectionScope(*Log_Vulkan);

    Free(layout.desc.bindings.data);
    vkDestroyDescriptorSetLayout(g_gfx_context.device, layout.layout, g_vk_alloc_callbacks);
    layout.* = .{};
}

GfxBindingPoolDesc :: struct {
    max_binding_sets : u32;
    max_uniform_buffers : u32;
    max_storage_buffers : u32;
    max_textures : u32;
    max_samplers : u32;
    max_combined_texture_samplers : u32;
    max_storage_images : u32;
}

GfxBindingPool :: struct {
    pool : VkDescriptorPool;
}

IsNull :: inline (pool : *GfxBindingPool) -> bool {
    return pool == null || pool.pool == VK_NULL_HANDLE;
}

CreateGfxBindingPool :: (name : string, desc : GfxBindingPoolDesc) -> GfxBindingPool {
    pool_sizes : [..]VkDescriptorPoolSize;
    pool_sizes.allocator = Temp;

    if desc.max_uniform_buffers > 0 {
        ArrayPush(*pool_sizes, .{type=.UNIFORM_BUFFER, descriptorCount=desc.max_uniform_buffers});
    }
    if desc.max_storage_buffers > 0 {
        ArrayPush(*pool_sizes, .{type=.STORAGE_BUFFER, descriptorCount=desc.max_storage_buffers});
    }
    if desc.max_textures > 0 {
        ArrayPush(*pool_sizes, .{type=.SAMPLED_IMAGE, descriptorCount=desc.max_textures});
    }
    if desc.max_samplers > 0 {
        ArrayPush(*pool_sizes, .{type=.SAMPLER, descriptorCount=desc.max_samplers});
    }
    if desc.max_combined_texture_samplers > 0 {
        ArrayPush(*pool_sizes, .{type=.COMBINED_IMAGE_SAMPLER, descriptorCount=desc.max_combined_texture_samplers});
    }
    if desc.max_storage_images > 0 {
        ArrayPush(*pool_sizes, .{type=.STORAGE_IMAGE, descriptorCount=desc.max_storage_images});
    }

    info : VkDescriptorPoolCreateInfo;
    info.maxSets = desc.max_binding_sets;
    info.poolSizeCount = xx pool_sizes.count;
    info.pPoolSizes = pool_sizes.data;

    pool : VkDescriptorPool;
    if vkCreateDescriptorPool(g_gfx_context.device, *info, g_vk_alloc_callbacks, *pool) != .SUCCESS {
        return .{};
    }

    SetDebugName(pool, TPrint("Descriptor Pool '%'", name));

    return .{pool=pool};
}

DestroyGfxBindingPool :: (pool : *GfxBindingPool) {
    vkDestroyDescriptorPool(g_gfx_context.device, pool.pool, g_vk_alloc_callbacks);
    pool.* = .{};
}

ResetGfxBindingPool :: (pool : *GfxBindingPool) {
    vkResetDescriptorPool(g_gfx_context.device, pool.pool, 0);
}

GfxBindingSet :: struct {
    set : VkDescriptorSet;
}

IsNull :: inline (set : *GfxBindingSet) -> bool {
    return set == null || set.set == VK_NULL_HANDLE;
}

GfxBindingPoolAllocResult :: enum {
    Success;
    OutOfPoolMemory;
    OutOfDeviceMemory;
    OutOfHostMemory;
    FragmentedPool;
    UnknownError;
}

MakeGfxBindingPoolAllocResult :: inline (result : VkResult) -> GfxBindingPoolAllocResult {
    if result == {
    case .SUCCESS; return .Success;
    case .ERROR_OUT_OF_POOL_MEMORY; return .OutOfPoolMemory;
    case .ERROR_OUT_OF_DEVICE_MEMORY; return .OutOfDeviceMemory;
    case .ERROR_OUT_OF_HOST_MEMORY; return .OutOfHostMemory;
    case .ERROR_FRAGMENTED_POOL; return .FragmentedPool;
    case; return .UnknownError;
    }
}

AllocGfxBindingSet :: (pool : *GfxBindingPool, layout : *GfxBindingSetLayout) -> GfxBindingSet, GfxBindingPoolAllocResult {
    info : VkDescriptorSetAllocateInfo;
    info.descriptorPool = pool.pool;
    info.descriptorSetCount = 1;
    info.pSetLayouts = *layout.layout;

    set : VkDescriptorSet;
    result := vkAllocateDescriptorSets(g_gfx_context.device, *info, *set);
    if result != .SUCCESS {
        return .{}, MakeGfxBindingPoolAllocResult(result);
    }

    return .{set=set}, .Success;
}

// Generates VkDescriptorBufferInfo, VkDescriptorImageInfo and VkWriteDescriptorSet then calls vkUpdateDescriptorSets automatically
// @AllowNull bindings are handled using the partially bound feature, so it is expected that when the binding is null it
// is not accessed in the shader. It is not the same thing as the null descriptor feature and failure to comply to this
// will result in crashes!
UpdateGfxBindingSet :: (set : *GfxBindingSet, value : $T) {
    #insert -> string {
        AppendBufferInfo :: (builder : *StringBuilder, name : string) {
            Appendln(builder, "    .{buffer=ifx value.%1.buffer then value.%1.buffer.buffer, offset=value.%1.offset, range=value.%1.size},", name);
        }

        AppendImageInfo :: (builder : *StringBuilder, name : string) {
            Appendln(builder, "    .{imageView=ifx value.%1.texture then value.%1.texture.image_view else VK_NULL_HANDLE, imageLayout=.READ_ONLY_OPTIMAL},", name);
        }

        AppendSamplerInfo :: (builder : *StringBuilder, name : string) {
            Appendln(builder, "    .{sampler=ifx value.%1.sampler then value.%1.sampler.sampler else VK_NULL_HANDLE},", name);
        }

        AppendCombinedImageSamplerInfo :: (builder : *StringBuilder, name : string) {
            Appendln(builder, "    .{sampler=ifx value.%1.sampler then value.%1.sampler.sampler else VK_NULL_HANDLE, imageView=ifx value.%1.texture then value.%1.texture.image_view else VK_NULL_HANDLE, imageLayout=.READ_ONLY_OPTIMAL},", name);
        }

        AppendStorageImageInfo :: (builder : *StringBuilder, name : string) {
            Appendln(builder, "    .{imageView=ifx value.%1.texture then value.%1.texture.image_view else VK_NULL_HANDLE, imageLayout=.GENERAL},", name);
        }

        builder : StringBuilder;
        info := type_info(T);

        Appendln(*builder, "// UpdateGfxBindingSet(%)", T);
        Appendln(*builder, "buffer_infos := VkDescriptorBufferInfo.[");

        max_possible_writes := 0;

        for info.members {
            if it.type.type == .ARRAY {
                continue;
            }

            type := GetGfxBindingType(it.type);
            if type == {
            case .UniformBuffer; #through;
            case .StorageBuffer;
                AppendBufferInfo(*builder, it.name);
                max_possible_writes += 1;
            }
        }

        Appendln(*builder, "];");

        Appendln(*builder, "image_infos := VkDescriptorImageInfo.[");

        for info.members {
            if it.type.type == .ARRAY {
                count := cast(*Type_Info_Array, it.type).array_count;
                type := GetGfxBindingType(cast(*Type_Info_Array, it.type).element_type);
                for i : 0..count - 1 {
                    if type == {
                    case .Texture;
                        AppendImageInfo(*builder, TPrint("%[%]", it.name, i));
                    case .Sampler;
                        AppendSamplerInfo(*builder, TPrint("%[%]", it.name, i));
                    case .CombinedTextureSampler;
                        AppendCombinedImageSamplerInfo(*builder, TPrint("%[%]", it.name, i));
                    case .StorageImage;
                        AppendStorageImageInfo(*builder, TPrint("%[%]", it.name, i));
                    }
                }

                max_possible_writes += count;
            } else {
                type := GetGfxBindingType(it.type);
                if type == {
                case .Texture;
                    AppendImageInfo(*builder, it.name);
                case .Sampler;
                    AppendSamplerInfo(*builder, it.name);
                case .CombinedTextureSampler;
                    AppendCombinedImageSamplerInfo(*builder, it.name);
                case .StorageImage;
                    AppendStorageImageInfo(*builder, it.name);
                }

                max_possible_writes += 1;
            }
        }

        Appendln(*builder, "];");

        AppendWrite :: (builder : *StringBuilder, allow_null : bool, binding : int, type : GfxBindingType, name : string, array_index : int, buffer_info_index : *int, image_info_index : *int) {
            if allow_null {
                if type == {
                case .UniformBuffer; #through;
                case .StorageBuffer;
                    Appendln(builder, "if !IsNull(value.%1.buffer) && value.%1.size > 0 {", name);

                case .Texture; #through;
                case .StorageImage;
                    Appendln(builder, "if !IsNull(value.%1) {", name);

                case .Sampler;
                    Appendln(builder, "if !IsNull(value.%1) {", name);

                case .CombinedTextureSampler;
                    Appendln(builder, "if !IsNull(value.%1.texture) {", name);
                }
            }

            if allow_null {
                Append(builder, "    ");
            }

            Appendln(builder, "write = ArrayPush(*writes);");

            if allow_null {
                Append(builder, "    ");
            }

            Append(builder,   "write.* = .{dstSet=set.set, dstBinding=%, descriptorType=.%, descriptorCount=1, dstArrayElement=%, ", binding, MakeVkDescriptorType(type), array_index);

            if type == {
            case .UniformBuffer; #through;
            case .StorageBuffer;
                Append(builder, "pBufferInfo=*buffer_infos[%]", buffer_info_index.*);
                buffer_info_index.* += 1;

            case .StorageImage; #through;
            case .Texture; #through;
            case .Sampler; #through;
            case .CombinedTextureSampler;
                Append(builder, "pImageInfo=*image_infos[%]", image_info_index.*);
                image_info_index.* += 1;
            }

            Appendln(builder, "};");

            if allow_null {
                Appendln(builder, "}");
            }
        }

        buffer_info_index := 0;
        image_info_index := 0;

        Appendln(*builder, "writes_stack_data : [%]VkWriteDescriptorSet = ---;", max_possible_writes);
        Appendln(*builder, "writes : [..]VkWriteDescriptorSet;");
        Appendln(*builder, "writes.allocator = Trap;");
        Appendln(*builder, "writes.data = writes_stack_data.data;");
        Appendln(*builder, "writes.allocated = writes_stack_data.count;");
        Appendln(*builder, "write : *VkWriteDescriptorSet;");

        for info.members {
            has_binding_note, binding := GetNote(it.notes, "Binding", int);
            allow_null := GetNote(it.notes, "AllowNull");

            if it.type.type == .ARRAY {
                elem_type := cast(*Type_Info_Array, it.type).element_type;
                elem_count := cast(*Type_Info_Array, it.type).array_count;
                type := GetGfxBindingType(elem_type);
                for i : 0..elem_count - 1 {
                    AppendWrite(*builder, allow_null, binding, type, TPrint("%[%]", it.name, i), i, *buffer_info_index, *image_info_index);
                }
            } else {
                type := GetGfxBindingType(it.type);
                AppendWrite(*builder, allow_null, binding, type, it.name, 0, *buffer_info_index, *image_info_index);
            }
        }

        return StringBuilderBuild(*builder);
    }

    vkUpdateDescriptorSets(g_gfx_context.device, xx writes.count, writes.data, 0, null);
}

// To help reduce error prone boilerplate code for layout creation and binding set allocation, we provide
// these types below. You can define a struct containing these members, and that struct can be used to both
// create a binding set layout as well as allocate a binding set.
// This is a simple solution that simplifies layout and binding set creation without using reflection (although
// reflection would probably simplify even more that process, and in particular would not require us to know
// the binding point indices on the CPU side).
// I am sure most engines use reflection to make this automatic. I don't believe this is a good design choice because
// the programmer has to setup the descriptor sets in the source code anyway, so it makes more sense to define the layouts
// in the source code too (though to be fair without code generation and type information this is maybe the only solution).
// Furthermore, your shaders cannot work if the bindings are not setup properly CPU side, so your ability to add new bindings
// in the shader and hot-reload is limited or even non-existent.

/* Example (not 1:1 with how you actually use the API):

MyParamSet :: struct {
    a_buffer : GfxBindingUniformBuffer; @Binding(0) @VertexStage @FragmentStage
    a_texture : GfxBindingTexture; @Binding(1) @AllowNull @FragmentStage
    many_textures : [10]GfxBindingTexture; @Binding(2) @FragmentStage
    a_sampler : GfxBindingSampler; @Binding(3) @FragmentStage
}

set_layout := CreateGfxBindingSetLayout(MyParamSet);

bindings : MyParamSet;
bindings.a_buffer = .{buffer=my_buffer, offset=0};
bindings.a_texture = null;
for bindings.many_textures {
    bindings.many_textures = GetTexture(it_index);
}
bindings.a_sample = my_sampler;

binding_set := CreateGfxBindingSet(*set_layout, bindings);

...

BindGraphicsBindingSet(*pass, 0, *binding_set);

*/

GfxBindingUniformBuffer :: struct {
    buffer : *GfxBuffer;
    offset : u32;
    size : u32;
}

GfxBindingStorageBuffer :: struct {
    buffer : *GfxBuffer;
    offset : u32;
    size : u32;
}

GfxBindingTexture :: struct {
    texture : *GfxTexture;
}

GfxBindingSampler :: struct {
    sampler : *GfxSampler;
}

GfxBindingCombinedTextureSampler :: struct {
    texture : *GfxTexture;
    sampler : *GfxSampler;
}

GfxBindingStorageImage :: struct {
    texture : *GfxTexture;
}

CreateGfxBindingSetLayout :: ($T : Type) -> GfxBindingSetLayout {
    desc : GfxBindingSetLayoutDesc;

    #insert -> string {
        info := type_info(T);
        struct_location := compiler_get_struct_location(get_current_workspace(), info);

        builder : StringBuilder;
        Appendln(*builder, "Name :: \"%\";", T);
        Appendln(*builder, "desc.bindings = GfxBindingDesc.[");

        for info.members {
            binding : u32;
            num_array_layers : u32 = 1;
            type : GfxBindingType;
            stage_flags : GfxShaderStageFlags;
            flags : GfxBindingFlags;

            if it.type.type == .ARRAY {
                num_array_layers = xx cast(*Type_Info_Array, it.type).array_count;
                type = GetGfxBindingType(cast(*Type_Info_Array, it.type).element_type);
            } else {
                type = GetGfxBindingType(it.type);
            }

            found_binding := false;
            for note : it.notes {
                if note == "AllowNull" {
                    flags |= .AllowNull;
                } if note == "VertexStage" {
                    stage_flags |= .Vertex;
                } else if note == "FragmentStage" {
                    stage_flags |= .Fragment;
                } else if note == "ComputeStage" {
                    stage_flags |= .Compute;
                } else if StringStartsWith(note, "Binding(") {
                    found_binding = true;
                    _note := StringAdvance(note, "Binding(".count);
                    value, ok, remainder := Basic.string_to_int(_note);
                    if !ok || remainder != ")" {
                        compiler_report(TPrint("Invalid @Binding note on member %", it.name), loc=struct_location);
                    }

                    binding = xx value;
                }
            }

            if !found_binding {
                compiler_report(TPrint("Missing @Binding note on member %", it.name), loc=struct_location);
            }

            if stage_flags == 0 {
                compiler_report(TPrint("Missing @VertexStage, @FragmentStage or @ComputeStage note on member %", it.name), loc=struct_location);
            }

            Appendln(*builder, "    .{binding=%, num_array_layers=%, type=.%, stage_flags=%, flags=%},", binding, num_array_layers, type, cast(u8, stage_flags), cast(u8, flags));
        }

        Appendln(*builder, "];");

        return StringBuilderBuild(*builder);
    }

    return CreateGfxBindingSetLayout(Name, desc);
}

GfxPixelFormat :: enum u8 {
    Invalid;

    R8UNorm;
    R8SNorm;
    R8UInt;
    R8SInt;
    RGBA8SRGB;
    RGBA8UNorm;
    RGBA8SNorm;
    RGBA8UInt;
    RGBA8SInt;
    BGRA8UNorm;
    BGRA8SRGB;
    R32UInt;
    R32SInt;
    RGBA16Float;
    RGBA32UInt;
    RGBA32SInt;
    RGBA32Float;

    Depth32FloatStencil8;
    Depth32Float;
    Stencil8;
}

GetPixelSize :: inline (pixel_format : GfxPixelFormat) -> u32 {
    if #complete pixel_format == {
    case .Invalid; return 0;
    case .R8UNorm; return 1;
    case .R8SNorm; return 1;
    case .R8UInt; return 1;
    case .R8SInt; return 1;
    case .RGBA8SRGB; return 4;
    case .RGBA8UNorm; return 4;
    case .RGBA8SNorm; return 4;
    case .RGBA8UInt; return 4;
    case .RGBA8SInt; return 4;
    case .BGRA8UNorm; return 4;
    case .BGRA8SRGB; return 4;
    case .R32UInt; return 4;
    case .R32SInt; return 4;
    case .RGBA16Float; return 8;
    case .RGBA32UInt; return 16;
    case .RGBA32SInt; return 16;
    case .RGBA32Float; return 16;
    case .Depth32FloatStencil8; return 5;
    case .Depth32Float; return 4;
    case .Stencil8; return 1;
    }

    return 0;
}

MakeVkFormat :: inline (pixel_format : GfxPixelFormat) -> VkFormat {
    if #complete pixel_format == {
    case .Invalid; return .UNDEFINED;
    case .R8UNorm; return .R8_UNORM;
    case .R8SNorm; return .R8_SNORM;
    case .R8UInt; return .R8_UINT;
    case .R8SInt; return .R8_SINT;
    case .RGBA8SRGB; return .R8G8B8A8_SRGB;
    case .RGBA8UNorm; return .R8G8B8A8_UNORM;
    case .RGBA8SNorm; return .R8G8B8A8_SNORM;
    case .RGBA8UInt; return .R8G8B8A8_UINT;
    case .RGBA8SInt; return .R8G8B8A8_SINT;
    case .BGRA8UNorm; return .B8G8R8A8_UNORM;
    case .BGRA8SRGB; return .B8G8R8A8_SRGB;
    case .R32UInt; return .R32_UINT;
    case .R32SInt; return .R32_SINT;
    case .RGBA16Float; return .R16G16B16A16_SFLOAT;
    case .RGBA32UInt; return .R32G32B32A32_UINT;
    case .RGBA32SInt; return .R32G32B32A32_SINT;
    case .RGBA32Float; return .R32G32B32A32_SFLOAT;
    case .Depth32FloatStencil8; return .D32_SFLOAT_S8_UINT;
    case .Depth32Float; return .D32_SFLOAT;
    case .Stencil8; return .S8_UINT;
    }
    return .UNDEFINED;
}

MakeGfxPixelFormat :: inline (format : VkFormat) -> GfxPixelFormat {
    if format == {
    case .UNDEFINED; return .Invalid;
    case .R8_UNORM; return .R8UNorm;
    case .R8_SNORM; return .R8SNorm;
    case .R8_UINT; return .R8UInt;
    case .R8_SINT; return .R8SInt;
    case .R8G8B8A8_SRGB; return .RGBA8SRGB;
    case .R8G8B8A8_UNORM; return .RGBA8UNorm;
    case .R8G8B8A8_SNORM; return .RGBA8SNorm;
    case .R8G8B8A8_UINT; return .RGBA8UInt;
    case .R8G8B8A8_SINT; return .RGBA8SInt;
    case .B8G8R8A8_UNORM; return .BGRA8UNorm;
    case .B8G8R8A8_SRGB; return .BGRA8SRGB;
    case .R32_UINT; return .R32UInt;
    case .R32_SINT; return .R32SInt;
    case .R16G16B16A16_SFLOAT; return .RGBA16Float;
    case .R32G32B32A32_UINT; return .RGBA32UInt;
    case .R32G32B32A32_SINT; return .RGBA32SInt;
    case .R32G32B32A32_SFLOAT; return .RGBA32Float;
    case .D32_SFLOAT_S8_UINT; return .Depth32FloatStencil8;
    case .D32_SFLOAT; return .Depth32Float;
    case .S8_UINT; return .Stencil8;
    }
    return .Invalid;
}

GfxVertexFormat :: enum {
    Invalid;

    Float;
    Float2;
    Float3;
    Float4;

    Char2;
    Char3;
    Char4;
    UChar2;
    UChar3;
    UChar4;

    Short2;
    Short3;
    Short4;
    UShort2;
    UShort3;
    UShort4;

    Int;
    Int2;
    Int3;
    Int4;
    UInt;
    UInt2;
    UInt3;
    UInt4;
}

MakeVkFormat :: (format : GfxVertexFormat, normalized : bool) -> VkFormat {
    if #complete format == {
    case .Invalid; return .UNDEFINED;
    case .Float; return .R32_SFLOAT;
    case .Float2; return .R32G32_SFLOAT;
    case .Float3; return .R32G32B32_SFLOAT;
    case .Float4; return .R32G32B32A32_SFLOAT;
    case .Char2; return ifx normalized then .R8G8_SNORM else .R8G8_SINT;
    case .Char3; return ifx normalized then .R8G8B8_SNORM else .R8G8B8_SINT;
    case .Char4; return ifx normalized then .R8G8B8A8_SNORM else .R8G8B8A8_SINT;
    case .UChar2; return ifx normalized then .R8G8_UNORM else .R8G8_UINT;
    case .UChar3; return ifx normalized then .R8G8B8_UNORM else .R8G8B8_UINT;
    case .UChar4; return ifx normalized then .R8G8B8A8_UNORM else .R8G8B8A8_UINT;
    case .Short2; return ifx normalized then .R16G16_SNORM else .R16G16_SINT;
    case .Short3; return ifx normalized then .R16G16B16_SNORM else .R16G16B16_SINT;
    case .Short4; return ifx normalized then .R16G16B16A16_SNORM else .R16G16B16A16_SINT;
    case .UShort2; return ifx normalized then .R16G16_UNORM else .R16G16_UINT;
    case .UShort3; return ifx normalized then .R16G16B16_UNORM else .R16G16B16_UINT;
    case .UShort4; return ifx normalized then .R16G16B16A16_UNORM else .R16G16B16A16_UINT;
    // No normalized 32-bit integer formats?
    case .Int; return .R32_SINT;
    case .Int2; return .R32G32_SINT;
    case .Int3; return .R32G32B32_SINT;
    case .Int4; return .R32G32B32A32_SINT;
    case .UInt; return .R32G32_UINT;
    case .UInt2; return .R32G32_UINT;
    case .UInt3; return .R32G32B32_UINT;
    case .UInt4; return .R32G32B32A32_UINT;
    }
}

MakeGfxVertexFormat :: inline (type : Type) -> GfxVertexFormat {
    if type == {
    case; return .Invalid;
    case float; return .Float;
    case Vec2f; return .Float2;
    case Vec3f; return .Float3;
    case Vec4f; return .Float4;
    case Vec2b; return .Char2;
    case Vec3b; return .Char3;
    case Vec4b; return .Char4;
    case Vec2ub; return .UChar2;
    case Vec3ub; return .UChar3;
    case Vec4ub; return .UChar4;
    case Vec2s; return .Short2;
    case Vec3s; return .Short3;
    case Vec4s; return .Short4;
    case Vec2us; return .UShort2;
    case Vec3us; return .UShort3;
    case Vec4us; return .UShort4;
    case s32; return .Int;
    case Vec2i; return .Int2;
    case Vec3i; return .Int3;
    case Vec4i; return .Int4;
    case u32; return .UInt;
    case Vec2u; return .UInt2;
    case Vec3u; return .UInt3;
    case Vec4u; return .UInt4;
    }
}

GfxVertexInputAttribute :: struct {
    location : u32;
    binding : u32;
    format : GfxVertexFormat;
    offset : u32;
    normalized : bool;
}

GfxVertexInputBufferBinding :: struct {
    binding : u32;
    stride : u32;
}

GfxVertexInputDesc :: struct {
    attributes : []GfxVertexInputAttribute;
    buffer_bindings : []GfxVertexInputBufferBinding;
}

MakeVertexInputDesc :: inline ($T : Type, buffer_binding : u32) -> GfxVertexInputDesc {
    return MakeVertexInputDesc(T, .[buffer_binding]);
}

MakeVertexInputDesc :: ($T : Type, buffer_bindings : []u32) -> GfxVertexInputDesc {
    desc : GfxVertexInputDesc;

    #insert -> string {
        builder : StringBuilder;

        info := type_info(T);
        Appendln(*builder, "attributes := GfxVertexInputAttribute.[");

        highest_offset := 0;
        for info.members {
            if it.flags & .CONSTANT || it.offset_in_bytes < highest_offset {
                continue;
            }

            highest_offset = it.offset_in_bytes + it.type.runtime_size;

            normalized := GetNote(it.notes, "Normalized");
            has_attrib_note, attrib_index := GetNote(it.notes, "VertexAttrib", int);
            has_buffer_note, buffer_index := GetNote(it.notes, "VertexBuffer", int);

            location := cast(u32, ifx has_attrib_note then attrib_index else it_index);
            format := MakeGfxVertexFormat(get_type(it.type));
            Assert(format != .Invalid, "Invalid vertex attribute type %", get_type(it.type));

            Appendln(*builder, "    .{location=%, binding=buffer_bindings[%], format=.%, offset=%, normalized=%},",
                location, buffer_index, format, it.offset_in_bytes, normalized);
        }

        Appendln(*builder, "];");

        return StringBuilderBuild(*builder);
    }

    desc.attributes = ArrayClone(attributes ,, Temp);
    desc.buffer_bindings = AllocArray(GfxVertexInputBufferBinding, buffer_bindings.count ,, Temp);
    for * desc.buffer_bindings {
        it.binding = buffer_bindings[it_index];
        it.stride = size_of(T);
    }

    return desc;
}

GfxPipelineLayoutDesc :: struct {
    binding_sets : []GfxBindingSetLayout;
}

GfxWindingOrder :: enum u8 {
    Clockwise;
    CounterClockwise;
}

GfxPrimitiveTopology :: enum u8 {
    PointList;
    LineList;
    TriangleList;
}

GfxFillMode :: enum u8 {
    Fill;
    Lines;
}

GfxPolygonFace :: enum u8 {
    None;
    Front;
    Back;
}

GfxRasterizerStateDesc :: struct {
    fill_mode : GfxFillMode = .Fill;
    cull_face : GfxPolygonFace = .Back;
    winding_order : GfxWindingOrder = .CounterClockwise;
    num_samples : u32 = 1;
}

GfxCompareOp :: enum u8 {
    None;
    Never;
    Always;
    Less;
    LessEqual;
    Greater;
    GreaterEqual;
    Equal;
    NotEqual;
}

MakeVkCompareOp :: inline (compare_op : GfxCompareOp) -> VkCompareOp {
    if #complete compare_op == {
    case; #through;
    case .None; Panic("Invalid value for compare_op");
    case .Never;        return .NEVER;
    case .Always;       return .ALWAYS;
    case .Less;         return .LESS;
    case .LessEqual;    return .LESS_OR_EQUAL;
    case .Greater;      return .GREATER;
    case .GreaterEqual; return .GREATER_OR_EQUAL;
    case .Equal;        return .EQUAL;
    case .NotEqual;     return .NOT_EQUAL;
    }
    return .MAX_ENUM;
}

GfxDepthStateDesc :: struct {
    test_enabled := false;
    write_enabled := false;
    compare_op : GfxCompareOp = .LessEqual;
}

GfxStencilOp :: enum u8 {
    Keep;
    Zero;
    Replace;
    IncrementClamp;
    IncrementWrap;
    DecrementClamp;
    DecrementWrap;
    Invert;
}

MakeVkStencilOp :: inline (stencil_op : GfxStencilOp) -> VkStencilOp {
    if #complete stencil_op == {
    case; Panic("Invalid value for stencil_op");
    case .Keep;           return .KEEP;
    case .Zero;           return .ZERO;
    case .Replace;        return .REPLACE;
    case .IncrementClamp; return .INCREMENT_AND_CLAMP;
    case .IncrementWrap;  return .INCREMENT_AND_WRAP;
    case .DecrementClamp; return .DECREMENT_AND_CLAMP;
    case .DecrementWrap;  return .DECREMENT_AND_WRAP;
    case .Invert;         return .INVERT;
    }
    return .MAX_ENUM;
}

GfxStencilFaceStateDesc :: struct {
    failed_op : GfxStencilOp = .Keep;
    depth_failed_op : GfxStencilOp = .Keep;
    passed_op : GfxStencilOp = .Keep;
    write_mask : u32 = 0xffffffff;
    read_mask : u32 = 0xffffffff;
    compare_op : GfxCompareOp = .Always;
}

GfxStencilStateDesc :: struct {
    test_enabled := false;
    front_face : GfxStencilFaceStateDesc;
    back_face : GfxStencilFaceStateDesc;
}

GfxBlendFactor :: enum u8 {
    One;
    Zero;
    SrcColor;
    OneMinusSrcColor;
    DstColor;
    OneMinusDstColor;
    SrcAlpha;
    OneMinusSrcAlpha;
    DstAlpha;
    OneMinusDstAlpha;
    ConstantColor;
    OneMinusConstantColor;
    ConstantAlpha;
    OneMinusConstantAlpha;
    SrcAlphaSaturate;
    Src1Color;
    OneMinusSrc1Color;
    Src1Alpha;
    OneMinusSrc1Alpha;
}

MakeVkBlendFactor :: inline (blend_factor : GfxBlendFactor) -> VkBlendFactor {
    if #complete blend_factor == {
    case; Panic("Invalid value for blend_factor");
    case .Zero;                  return .ZERO;
    case .One;                   return .ONE;
    case .SrcColor;              return .SRC_COLOR;
    case .OneMinusSrcColor;      return .ONE_MINUS_SRC_COLOR;
    case .DstColor;              return .DST_COLOR;
    case .OneMinusDstColor;      return .ONE_MINUS_DST_COLOR;
    case .SrcAlpha;              return .SRC_ALPHA;
    case .OneMinusSrcAlpha;      return .ONE_MINUS_SRC_ALPHA;
    case .DstAlpha;              return .DST_ALPHA;
    case .OneMinusDstAlpha;      return .ONE_MINUS_DST_ALPHA;
    case .ConstantColor;         return .CONSTANT_COLOR;
    case .OneMinusConstantColor; return .ONE_MINUS_CONSTANT_COLOR;
    case .ConstantAlpha;         return .CONSTANT_ALPHA;
    case .OneMinusConstantAlpha; return .ONE_MINUS_CONSTANT_ALPHA;
    case .SrcAlphaSaturate;      return .SRC_ALPHA_SATURATE;
    case .Src1Color;             return .SRC1_COLOR;
    case .OneMinusSrc1Color;     return .ONE_MINUS_SRC1_COLOR;
    case .Src1Alpha;             return .SRC1_ALPHA;
    case .OneMinusSrc1Alpha;     return .ONE_MINUS_SRC1_ALPHA;
    }
    return .MAX_ENUM;
}

GfxBlendOp :: enum u8 {
    Add;
    Subtract;
    ReverseSubtract;
    Min;
    Max;
}

MakeVkBlendOp :: inline (blend_op : GfxBlendOp) -> VkBlendOp {
    if #complete blend_op == {
    case .Add;             return .ADD;
    case .Subtract;        return .SUBTRACT;
    case .ReverseSubtract; return .REVERSE_SUBTRACT;
    case .Min;             return .MIN;
    case .Max;             return .MAX;
    }
    return .MAX_ENUM;
}

GfxBlendStateDesc :: struct {
    enabled := false;
    src_color_factor : GfxBlendFactor = .SrcAlpha;
    dst_color_factor : GfxBlendFactor = .OneMinusSrcAlpha;
    src_alpha_factor : GfxBlendFactor = .SrcAlpha;
    dst_alpha_factor : GfxBlendFactor = .OneMinusSrcAlpha;
    color_op : GfxBlendOp = .Add;
    alpha_op : GfxBlendOp = .Add;
}

// I don't like having this concept in the abstraction layer as I don't find this very useful.
// Currently it is needed so we can bind the global frame binding set at the beginning of the
// frame outside of any render passes (and without needing a full pipeline).
GfxPipelineLayout :: struct {
    layout : VkPipelineLayout;
}

IsNull :: inline (layout : *GfxPipelineLayout) -> bool {
    return layout == null || layout.layout == VK_NULL_HANDLE;
}

CreateGfxPipelineLayout :: (name : string, desc : GfxPipelineLayoutDesc) -> GfxPipelineLayout {
    LogSectionScope(*Log_Vulkan);

    layout_info : VkPipelineLayoutCreateInfo;
    layout_info.setLayoutCount = xx desc.binding_sets.count;
    layout_info.pSetLayouts = Alloc(VkDescriptorSetLayout, desc.binding_sets.count, initialize=true ,, Temp);
    for desc.binding_sets {
        layout_info.pSetLayouts[it_index] = it.layout;
    }

    layout : VkPipelineLayout;
    if vkCreatePipelineLayout(g_gfx_context.device, *layout_info, g_vk_alloc_callbacks, *layout) != .SUCCESS {
        return .{};
    }

    SetDebugName(layout, TPrint("Pipeline Layout '%'", name));

    return .{layout=layout};
}

DestroyGfxPipelineLayout :: (layout : *GfxPipelineLayout) {
    vkDestroyPipelineLayout(g_gfx_context.device, layout.layout, g_vk_alloc_callbacks);
    layout.* = .{};
}

GfxGraphicsPipelineDesc :: struct {
    vertex_shader : *GfxShader;
    fragment_shader : *GfxShader;

    layout : GfxPipelineLayoutDesc;
    vertex_input : GfxVertexInputDesc;
    primitive_topology : GfxPrimitiveTopology = .TriangleList;
    rasterizer_state : GfxRasterizerStateDesc;
    depth_state : GfxDepthStateDesc;
    stencil_state : GfxStencilStateDesc;

    num_color_attachments : u32;

    blend_states : [Gfx_Max_Color_Attachments]GfxBlendStateDesc;
    color_formats : [Gfx_Max_Color_Attachments]GfxPixelFormat;
    depth_format : GfxPixelFormat;
    stencil_format : GfxPixelFormat;
}

AddColorAttachment :: (desc : *GfxGraphicsPipelineDesc, format : GfxPixelFormat) {
    desc.color_formats[desc.num_color_attachments] = format;
    desc.num_color_attachments += 1;
}

GfxGraphicsPipeline :: struct {
    layout : GfxPipelineLayout;
    pipeline : VkPipeline;
    desc : GfxGraphicsPipelineDesc;
}

IsNull :: inline (pipeline : *GfxGraphicsPipeline) -> bool {
    return pipeline == null || pipeline.pipeline == VK_NULL_HANDLE || IsNull(*pipeline.layout);
}

CreateGfxGraphicsPipeline :: (name : string, desc : GfxGraphicsPipelineDesc) -> GfxGraphicsPipeline {
    LogSectionScope(*Log_Vulkan);

    layout := CreateGfxPipelineLayout(name, desc.layout);
    if IsNull(*layout) {
        return .{};
    }

    vertex_stage : VkPipelineShaderStageCreateInfo;
    vertex_stage.stage = .VERTEX_BIT;
    vertex_stage.pName = "main";
    vertex_stage.module = desc.vertex_shader.module;

    fragment_stage : VkPipelineShaderStageCreateInfo;
    if !IsNull(desc.fragment_shader) {
        fragment_stage.stage = .FRAGMENT_BIT;
        fragment_stage.pName = "main";
        fragment_stage.module = desc.fragment_shader.module;
    }

    shader_stages := VkPipelineShaderStageCreateInfo.[vertex_stage, fragment_stage];

    vertex_input_state : VkPipelineVertexInputStateCreateInfo;
    vertex_input_state.vertexBindingDescriptionCount = xx desc.vertex_input.buffer_bindings.count;
    vertex_input_state.pVertexBindingDescriptions = Alloc(VkVertexInputBindingDescription, desc.vertex_input.buffer_bindings.count, initialize=true ,, Temp);
    for desc.vertex_input.buffer_bindings {
        vertex_input_state.pVertexBindingDescriptions[it_index].binding = it.binding;
        vertex_input_state.pVertexBindingDescriptions[it_index].stride = it.stride;
        vertex_input_state.pVertexBindingDescriptions[it_index].inputRate = .VERTEX;
    }

    vertex_input_state.vertexAttributeDescriptionCount = xx desc.vertex_input.attributes.count;
    vertex_input_state.pVertexAttributeDescriptions = Alloc(VkVertexInputAttributeDescription, desc.vertex_input.attributes.count, initialize=true ,, Temp);
    for desc.vertex_input.attributes {
        vertex_input_state.pVertexAttributeDescriptions[it_index].location = it.location;
        vertex_input_state.pVertexAttributeDescriptions[it_index].binding = it.binding;
        vertex_input_state.pVertexAttributeDescriptions[it_index].format = MakeVkFormat(it.format, it.normalized);
        vertex_input_state.pVertexAttributeDescriptions[it_index].offset = it.offset;
    }

    input_assembly_state : VkPipelineInputAssemblyStateCreateInfo;
    if #complete desc.primitive_topology == {
    case .PointList;    input_assembly_state.topology = .POINT_LIST;
    case .LineList;     input_assembly_state.topology = .LINE_LIST;
    case .TriangleList; input_assembly_state.topology = .TRIANGLE_LIST;
    }

    dynamic_states := VkDynamicState.[.VIEWPORT, .SCISSOR, .BLEND_CONSTANTS, .STENCIL_REFERENCE];
    dynamic_state : VkPipelineDynamicStateCreateInfo;
    dynamic_state.dynamicStateCount = dynamic_states.count;
    dynamic_state.pDynamicStates = dynamic_states.data;

    viewport_state : VkPipelineViewportStateCreateInfo;
    viewport_state.viewportCount = 1;
    viewport_state.scissorCount = 1;

    rasterizer_state : VkPipelineRasterizationStateCreateInfo;
    if #complete desc.rasterizer_state.fill_mode == {
    case .Fill;  rasterizer_state.polygonMode = .FILL;
    case .Lines; rasterizer_state.polygonMode = .LINE;
    }

    rasterizer_state.lineWidth = 1;
    if #complete desc.rasterizer_state.cull_face == {
    case .None;  rasterizer_state.cullMode = 0;
    case .Front; rasterizer_state.cullMode = .FRONT_BIT;
    case .Back;  rasterizer_state.cullMode = .BACK_BIT;
    }

    if #complete desc.rasterizer_state.winding_order == {
    case .Clockwise;        rasterizer_state.frontFace = .CLOCKWISE;
    case .CounterClockwise; rasterizer_state.frontFace = .COUNTER_CLOCKWISE;
    }

    multisample_state : VkPipelineMultisampleStateCreateInfo;
    multisample_state.sampleShadingEnable = VK_FALSE;

    if desc.rasterizer_state.num_samples == {
    case 1;  multisample_state.rasterizationSamples = ._1_BIT;
    case 2;  multisample_state.rasterizationSamples = ._2_BIT;
    case 4;  multisample_state.rasterizationSamples = ._4_BIT;
    case 8;  multisample_state.rasterizationSamples = ._8_BIT;
    case 16; multisample_state.rasterizationSamples = ._16_BIT;
    case 32; multisample_state.rasterizationSamples = ._32_BIT;
    case 64; multisample_state.rasterizationSamples = ._64_BIT;
    case; Panic("Invalid sample count % for texture (expected 1, 2, 4, 8, 16, 32 or 64)", desc.rasterizer_state.num_samples);
    }

    blend_states : [Gfx_Max_Color_Attachments]VkPipelineColorBlendAttachmentState;
    for desc.blend_states {
        blend_states[it_index].colorWriteMask = .R_BIT | .G_BIT | .B_BIT | .A_BIT;
        blend_states[it_index].blendEnable = cast(VkBool32, it.enabled);
        blend_states[it_index].srcColorBlendFactor = MakeVkBlendFactor(it.src_color_factor);
        blend_states[it_index].dstColorBlendFactor = MakeVkBlendFactor(it.dst_color_factor);
        blend_states[it_index].srcAlphaBlendFactor = MakeVkBlendFactor(it.src_alpha_factor);
        blend_states[it_index].dstAlphaBlendFactor = MakeVkBlendFactor(it.dst_alpha_factor);
        blend_states[it_index].colorBlendOp = MakeVkBlendOp(it.color_op);
        blend_states[it_index].alphaBlendOp = MakeVkBlendOp(it.alpha_op);
    }

    blend_state : VkPipelineColorBlendStateCreateInfo;
    blend_state.attachmentCount = desc.num_color_attachments;
    blend_state.pAttachments = blend_states.data;

    depth_stencil_state : VkPipelineDepthStencilStateCreateInfo;
    depth_stencil_state.depthTestEnable = cast(VkBool32, desc.depth_state.test_enabled);
    depth_stencil_state.depthWriteEnable = cast(VkBool32, desc.depth_state.write_enabled);
    depth_stencil_state.depthCompareOp = MakeVkCompareOp(desc.depth_state.compare_op);
    depth_stencil_state.stencilTestEnable = cast(VkBool32, desc.stencil_state.test_enabled);

    for i : 0..1 {
        result := ifx i == 0 then *depth_stencil_state.front else *depth_stencil_state.back;
        stencil := ifx i == 0 then *desc.stencil_state.front_face else *desc.stencil_state.back_face;

        result.failOp = MakeVkStencilOp(stencil.failed_op);
        result.passOp = MakeVkStencilOp(stencil.passed_op);
        result.depthFailOp = MakeVkStencilOp(stencil.depth_failed_op);
        result.compareOp = MakeVkCompareOp(stencil.compare_op);
        result.writeMask = stencil.write_mask;
        result.compareMask = stencil.read_mask;
    }

    color_attachments : [Gfx_Max_Color_Attachments]VkFormat;
    for desc.color_formats {
        color_attachments[it_index] = MakeVkFormat(it);
    }

    rendering_info : VkPipelineRenderingCreateInfo;
    rendering_info.colorAttachmentCount = desc.num_color_attachments;
    rendering_info.pColorAttachmentFormats = color_attachments.data;
    rendering_info.depthAttachmentFormat = MakeVkFormat(desc.depth_format);
    rendering_info.stencilAttachmentFormat = MakeVkFormat(desc.stencil_format);

    pipeline_info : VkGraphicsPipelineCreateInfo;
    pipeline_info.pNext = *rendering_info;
    pipeline_info.stageCount = xx ifx IsNull(desc.fragment_shader) then 1 else 2;
    pipeline_info.pStages = shader_stages.data;
    pipeline_info.pVertexInputState = *vertex_input_state;
    pipeline_info.pInputAssemblyState = *input_assembly_state;
    pipeline_info.pViewportState = *viewport_state;
    pipeline_info.pRasterizationState = *rasterizer_state;
    pipeline_info.pMultisampleState = *multisample_state;
    pipeline_info.pDepthStencilState = *depth_stencil_state;
    pipeline_info.pColorBlendState = *blend_state;
    pipeline_info.pDynamicState = *dynamic_state;
    pipeline_info.layout = layout.layout;

    pipeline : VkPipeline;
    if vkCreateGraphicsPipelines(g_gfx_context.device, VK_NULL_HANDLE, 1, *pipeline_info, g_vk_alloc_callbacks, *pipeline) != .SUCCESS {
        DestroyGfxPipelineLayout(*layout);
        return .{};
    }

    SetDebugName(pipeline, TPrint("Graphics Pipeline '%'", name));

    copied_desc := desc;
    copied_desc.vertex_input.attributes = ArrayClone(desc.vertex_input.attributes);
    copied_desc.vertex_input.buffer_bindings = ArrayClone(desc.vertex_input.buffer_bindings);

    return .{layout=layout, pipeline=pipeline, desc=copied_desc};
}

DestroyGfxGraphicsPipeline :: (pipeline : *GfxGraphicsPipeline) {
    LogSectionScope(*Log_Vulkan);

    Free(pipeline.desc.vertex_input.attributes.data);
    Free(pipeline.desc.vertex_input.buffer_bindings.data);

    DestroyGfxPipelineLayout(*pipeline.layout);
    vkDestroyPipeline(g_gfx_context.device, pipeline.pipeline, g_vk_alloc_callbacks);
    pipeline.* = .{};
}

GfxComputePipelineDesc :: struct {
    shader : *GfxShader;
    layout : GfxPipelineLayoutDesc;
}

GfxComputePipeline :: struct {
    layout : GfxPipelineLayout;
    pipeline : VkPipeline;
    desc : GfxComputePipelineDesc;
}

IsNull :: inline (pipeline : *GfxComputePipeline) -> bool {
    return pipeline == null || pipeline.pipeline == VK_NULL_HANDLE || IsNull(*pipeline.layout);
}

CreateGfxComputePipeline :: (name : string, desc : GfxComputePipelineDesc) -> GfxComputePipeline {
    LogSectionScope(*Log_Vulkan);

    layout := CreateGfxPipelineLayout(name, desc.layout);
    if IsNull(*layout) {
        return .{};
    }

    create_info : VkComputePipelineCreateInfo;
    create_info.stage.stage = .COMPUTE_BIT;
    create_info.stage.pName = "main";
    create_info.stage.module = desc.shader.module;
    create_info.layout = layout.layout;

    pipeline : VkPipeline;
    if vkCreateComputePipelines(g_gfx_context.device, VK_NULL_HANDLE, 1, *create_info, g_vk_alloc_callbacks, *pipeline) != .SUCCESS {
        DestroyGfxPipelineLayout(*layout);
        return .{};
    }

    SetDebugName(pipeline, TPrint("Compute Pipeline '%'", name));

    return .{layout=layout, pipeline=pipeline, desc=desc};
}

DestroyGfxComputePipeline :: (pipeline : *GfxComputePipeline) {
    LogSectionScope(*Log_Vulkan);

    DestroyGfxPipelineLayout(*pipeline.layout);
    vkDestroyPipeline(g_gfx_context.device, pipeline.pipeline, g_vk_alloc_callbacks);
    pipeline.* = .{};
}

GfxBufferUsageFlags :: enum_flags {
    TransferSrc;
    TransferDst;
    UniformBuffer;
    StorageBuffer;
    IndexBuffer;
    VertexBuffer;
}

GfxBufferMemoryUsage :: enum {
    GPUOnly;
    Upload;
    Readback;
}

GfxBufferDesc :: struct {
    size : u64;
    usage : GfxBufferUsageFlags;
    memory_usage : GfxBufferMemoryUsage;
}

GfxBuffer :: struct {
    buffer : VkBuffer;
    allocation : VmaAllocation;
    desc : GfxBufferDesc;
}

IsNull :: inline (buffer : *GfxBuffer) -> bool {
    return buffer == null || buffer.buffer == VK_NULL_HANDLE;
}

CreateGfxBuffer :: (name : string, desc : GfxBufferDesc) -> GfxBuffer {
    LogSectionScope(*Log_Vulkan);

    buffer_info : VkBufferCreateInfo;
    buffer_info.size = desc.size;
    if desc.usage & .TransferSrc {
        buffer_info.usage |= .TRANSFER_SRC_BIT;
    }
    if desc.usage & .TransferDst {
        buffer_info.usage |= .TRANSFER_DST_BIT;
    }
    if desc.usage & .UniformBuffer {
        buffer_info.usage |= .UNIFORM_BUFFER_BIT;
    }
    if desc.usage & .StorageBuffer {
        buffer_info.usage |= .STORAGE_BUFFER_BIT;
    }
    if desc.usage & .IndexBuffer {
        buffer_info.usage |= .INDEX_BUFFER_BIT;
    }
    if desc.usage & .VertexBuffer {
        buffer_info.usage |= .VERTEX_BUFFER_BIT;
    }
    buffer_info.sharingMode = .EXCLUSIVE;
    buffer_info.queueFamilyIndexCount = 1;
    buffer_info.pQueueFamilyIndices = *g_gfx_context.general_purpose_queue_index;

    alloc_info : VmaAllocationCreateInfo;
    alloc_info.usage = .AUTO;
    if #complete desc.memory_usage == {
    case .GPUOnly;
        alloc_info.flags = .DEDICATED_MEMORY_BIT;
    case .Upload;
        alloc_info.flags = .HOST_ACCESS_SEQUENTIAL_WRITE_BIT | .MAPPED_BIT;
    case .Readback;
        alloc_info.flags = .HOST_ACCESS_RANDOM_BIT | .MAPPED_BIT;
    }

    buffer : VkBuffer;
    allocation : VmaAllocation;
    if vmaCreateBuffer(g_gfx_context.allocator, *buffer_info, *alloc_info, *buffer, *allocation, null) != .SUCCESS {
        return .{};
    }

    SetDebugName(buffer, TPrint("Buffer '%'", name));

    return .{buffer=buffer, allocation=allocation, desc=desc};
}

DestroyGfxBuffer :: (buffer : *GfxBuffer) {
    LogSectionScope(*Log_Vulkan);

    vmaDestroyBuffer(g_gfx_context.allocator, buffer.buffer, buffer.allocation);
    buffer.* = .{};
}

QueueDestroyGfxBuffer :: (buffer : *GfxBuffer) {
    collector := *g_gfx_context.buffer_collectors[g_gfx_context.frame_in_flight];
    AddGarbage(collector, buffer);
    buffer.* = .{};
}

GfxTextureType :: enum u8 {
    Invalid;
    Texture1D;
    Texture2D;
    Texture2DMS;
    Texture3D;
    TextureCube;
    Texture1DArray;
    Texture2DArray;
    Texture2DMSArray;
    TextureCubeArray;
}

GfxTextureUsage :: enum_flags u8 {
    TransferSrc;
    TransferDst;
    Sampled;
    Storage;
    ColorAttachment;
    DepthStencilAttachment;
}

GfxTextureDesc :: struct {
    type : GfxTextureType;
    pixel_format : GfxPixelFormat;
    usage : GfxTextureUsage;
    width : u32 = 1;
    height : u32 = 1;
    depth : u32 = 1;
    num_array_layers : u32 = 1;
    num_mipmap_levels : u32 = 1;
    num_samples : u32 = 1;
}

GetNumMipmapLevelsForTextureSize :: (width : u32, height : u32) -> u32 {
    return cast(u32, Floor(Log2(xx Max(width, height)))) + 1;
}

GetTextureMemoryRequirementsForLevel0 :: (desc : GfxTextureAndViewDesc) -> u64 {
    size := desc.width * desc.height * desc.depth * desc.num_array_layers * GetPixelSize(desc.pixel_format);
    if desc.type == .TextureCube || desc.type == .TextureCubeArray {
        size *= 6;
    }

    return size;
}

GfxTextureViewDesc :: struct {
    type : GfxTextureType;
    pixel_format : GfxPixelFormat;
    first_array_layer : u32;
    num_array_layers : u32 = 1;
    first_mipmap_level : u32;
    num_mipmap_levels : u32 = 1;
}

GfxTextureAndViewDesc :: struct {
    type : GfxTextureType;
    pixel_format : GfxPixelFormat;
    usage : GfxTextureUsage;
    width : u32 = 1;
    height : u32 = 1;
    depth : u32 = 1;
    first_array_layer : u32;
    num_array_layers : u32 = 1;
    first_mipmap_level : u32;
    num_mipmap_levels : u32 = 1;
    num_samples : u32 = 1;
}

GetTextureMipWidth :: (w : u32, mipmap_level : int) -> u32 {
    for 1..mipmap_level {
        w = Max(w / 2, 1);
    }

    return w;
}

GetTextureMipHeight :: (h : u32, mipmap_level : int) -> u32 {
    for 1..mipmap_level {
        h = Max(h / 2, 1);
    }

    return h;
}

GetTextureMipSize :: (w : u32, h : u32, mipmap_level : int) -> w : u32, h : u32 {
    for 1..mipmap_level {
        w = Max(w / 2, 1);
        h = Max(h / 2, 1);
    }

    return w, h;
}

GetTextureMipSize :: (desc : GfxTextureAndViewDesc, mipmap_level : int) -> w : u32, h : u32 {
    w, h := GetTextureMipSize(desc.width, desc.height, mipmap_level);
    return w, h;
}

MakeGfxTextureAndViewDesc :: inline (desc : GfxTextureDesc) -> GfxTextureAndViewDesc {
    return .{
        type=desc.type,
        pixel_format=desc.pixel_format,
        usage=desc.usage,
        width=desc.width,
        height=desc.height,
        depth=desc.depth,
        num_array_layers=desc.num_array_layers,
        num_mipmap_levels=desc.num_mipmap_levels,
        num_samples=desc.num_samples,
    };
}

MakeGfxTextureAndViewDesc :: inline (desc : GfxTextureAndViewDesc, view_desc : GfxTextureViewDesc) -> GfxTextureAndViewDesc {
    result := desc;
    result.type = view_desc.type;
    result.pixel_format = view_desc.pixel_format;
    result.first_array_layer = view_desc.first_array_layer;
    result.num_array_layers = view_desc.num_array_layers;
    result.first_mipmap_level = view_desc.first_mipmap_level;
    result.num_mipmap_levels = view_desc.num_mipmap_levels;

    return result;
}

GfxTexture :: struct {
    image : VkImage;
    image_view : VkImageView; // Default view for this texture
    allocation : VmaAllocation;
    desc : GfxTextureAndViewDesc;
}

MakeVkImageSubresourceRange :: (desc : GfxTextureAndViewDesc) -> VkImageSubresourceRange {
    subresource : VkImageSubresourceRange;
    subresource.baseMipLevel = desc.first_mipmap_level;
    subresource.levelCount = desc.num_mipmap_levels;
    subresource.baseArrayLayer = desc.first_array_layer;
    subresource.layerCount = desc.num_array_layers;

    if desc.type == .TextureCube || desc.type == .TextureCubeArray {
        subresource.layerCount *= 6;
    }

    if desc.pixel_format == {
    case .Depth32FloatStencil8;
        subresource.aspectMask = .DEPTH_BIT | .STENCIL_BIT;
    case .Depth32Float;
        subresource.aspectMask = .DEPTH_BIT;
    case .Stencil8;
        subresource.aspectMask = .STENCIL_BIT;
    case;
        subresource.aspectMask = .COLOR_BIT;
    }

    return subresource;
}

MakeVkImageSubresourceLayers :: (desc : GfxTextureAndViewDesc, mip_level : u32) -> VkImageSubresourceLayers {
    subresource : VkImageSubresourceLayers;
    subresource.mipLevel = mip_level;
    subresource.baseArrayLayer = desc.first_array_layer;
    subresource.layerCount = desc.num_array_layers;

    if desc.type == .TextureCube || desc.type == .TextureCubeArray {
        subresource.layerCount *= 6;
    }

    if desc.pixel_format == {
    case .Depth32FloatStencil8;
        subresource.aspectMask = .DEPTH_BIT | .STENCIL_BIT;
    case .Depth32Float;
        subresource.aspectMask = .DEPTH_BIT;
    case .Stencil8;
        subresource.aspectMask = .STENCIL_BIT;
    case;
        subresource.aspectMask = .COLOR_BIT;
    }

    return subresource;
}

IsNull :: inline (texture : *GfxTexture) -> bool {
    return texture == null || texture.image == VK_NULL_HANDLE;
}

CreateGfxTexture :: (name : string, desc : GfxTextureDesc) -> GfxTexture {
    LogSectionScope(*Log_Vulkan);

    image_info : VkImageCreateInfo;
    if #complete desc.type == {
    case .Invalid; Panic("Invalid image type");
    case .Texture1D;        image_info.imageType = ._1D;
    case .Texture2D;        image_info.imageType = ._2D;
    case .Texture2DMS;      image_info.imageType = ._2D;
    case .Texture3D;        image_info.imageType = ._3D;
    case .TextureCube;      image_info.imageType = ._2D;
    case .Texture1DArray;   image_info.imageType = ._1D;
    case .Texture2DArray;   image_info.imageType = ._2D;
    case .Texture2DMSArray; image_info.imageType = ._2D;
    case .TextureCubeArray; image_info.imageType = ._2D;
    }

    if desc.num_samples == {
    case 1;  image_info.samples = ._1_BIT;
    case 2;  image_info.samples = ._2_BIT;
    case 4;  image_info.samples = ._4_BIT;
    case 8;  image_info.samples = ._8_BIT;
    case 16; image_info.samples = ._16_BIT;
    case 32; image_info.samples = ._32_BIT;
    case 64; image_info.samples = ._64_BIT;
    case;
        Panic("Invalid sample count % for texture (expected 1, 2, 4, 8, 16, 32 or 64)", desc.num_samples);
    }

    image_info.format = MakeVkFormat(desc.pixel_format);
    image_info.tiling = .OPTIMAL;

    image_info.arrayLayers = desc.num_array_layers;
    image_info.mipLevels = desc.num_mipmap_levels;
    image_info.extent = .{desc.width, desc.height, desc.depth};

    if desc.type == .TextureCube || desc.type == .TextureCubeArray {
        image_info.flags |= .CUBE_COMPATIBLE_BIT;
        image_info.arrayLayers *= 6;
    }

    if desc.usage & .TransferSrc {
        image_info.usage |= .TRANSFER_SRC_BIT;
    }
    if desc.usage & .TransferDst {
        image_info.usage |= .TRANSFER_DST_BIT;
    }
    if desc.usage & .Sampled {
        image_info.usage |= .SAMPLED_BIT;
    }
    if desc.usage & .Storage {
        image_info.usage |= .STORAGE_BIT;
    }
    if desc.usage & .ColorAttachment {
        image_info.usage |= .COLOR_ATTACHMENT_BIT;
    }
    if desc.usage & .DepthStencilAttachment {
        image_info.usage |= .DEPTH_STENCIL_ATTACHMENT_BIT;
    }

    image_info.sharingMode = .EXCLUSIVE;
    image_info.queueFamilyIndexCount = 1;
    image_info.pQueueFamilyIndices = *g_gfx_context.general_purpose_queue_index;

    alloc_info : VmaAllocationCreateInfo;
    alloc_info.usage = .AUTO;
    alloc_info.flags = .DEDICATED_MEMORY_BIT;
    alloc_info.priority = 1;

    image : VkImage;
    allocation : VmaAllocation;
    if vmaCreateImage(g_gfx_context.allocator, *image_info, *alloc_info, *image, *allocation, null) != .SUCCESS {
        return .{};
    }

    view_info : VkImageViewCreateInfo;
    view_info.image = image;
    view_info.format = image_info.format;

    if #complete desc.type == {
    case .Invalid;
    case .Texture1D;        view_info.viewType = ._1D;
    case .Texture2D;        view_info.viewType = ._2D;
    case .Texture2DMS;      view_info.viewType = ._2D;
    case .Texture3D;        view_info.viewType = ._3D;
    case .TextureCube;      view_info.viewType = .CUBE;
    case .Texture1DArray;   view_info.viewType = ._1D_ARRAY;
    case .Texture2DArray;   view_info.viewType = ._2D_ARRAY;
    case .Texture2DMSArray; view_info.viewType = ._2D_ARRAY;
    case .TextureCubeArray; view_info.viewType = .CUBE_ARRAY;
    }

    if desc.pixel_format == {
    case .Depth32FloatStencil8;
        view_info.subresourceRange.aspectMask = .DEPTH_BIT | .STENCIL_BIT;
    case .Depth32Float;
        view_info.subresourceRange.aspectMask = .DEPTH_BIT;
    case .Stencil8;
        view_info.subresourceRange.aspectMask = .STENCIL_BIT;
    case;
        view_info.subresourceRange.aspectMask = .COLOR_BIT;
    }

    view_info.subresourceRange.baseMipLevel = 0;
    view_info.subresourceRange.levelCount = image_info.mipLevels;
    view_info.subresourceRange.baseArrayLayer = 0;
    view_info.subresourceRange.layerCount = image_info.arrayLayers;

    image_view : VkImageView;
    if vkCreateImageView(g_gfx_context.device, *view_info, g_vk_alloc_callbacks, *image_view) != .SUCCESS {
        vmaDestroyImage(g_gfx_context.allocator, image, allocation);
        return .{};
    }

    SetDebugName(image, TPrint("Image '%'", name));
    SetDebugName(image_view, TPrint("Image View '%'", name));

    return .{image=image, image_view=image_view, allocation=allocation, desc=MakeGfxTextureAndViewDesc(desc)};
}

DestroyGfxTexture :: (texture : *GfxTexture) {
    LogSectionScope(*Log_Vulkan);

    vkDestroyImageView(g_gfx_context.device, texture.image_view, g_vk_alloc_callbacks);
    vmaDestroyImage(g_gfx_context.allocator, texture.image, texture.allocation);
    texture.* = .{};
}

QueueDestroyGfxTexture :: (texture : *GfxTexture) {
    collector := *g_gfx_context.texture_collectors[g_gfx_context.frame_in_flight];
    AddGarbage(collector, texture);
    texture.* = .{};
}

CreateGfxTextureView :: (name : string, desc : GfxTextureViewDesc, texture : *GfxTexture) -> GfxTexture {
    if IsNull(texture) {
        return .{};
    }

    view_info : VkImageViewCreateInfo;
    view_info.image = texture.image;
    view_info.format = MakeVkFormat(desc.pixel_format);

    if #complete desc.type == {
    case .Invalid;
    case .Texture1D;        view_info.viewType = ._1D;
    case .Texture2D;        view_info.viewType = ._2D;
    case .Texture2DMS;      view_info.viewType = ._2D;
    case .Texture3D;        view_info.viewType = ._3D;
    case .TextureCube;      view_info.viewType = .CUBE;
    case .Texture1DArray;   view_info.viewType = ._1D_ARRAY;
    case .Texture2DArray;   view_info.viewType = ._2D_ARRAY;
    case .Texture2DMSArray; view_info.viewType = ._2D_ARRAY;
    case .TextureCubeArray; view_info.viewType = .CUBE_ARRAY;
    }

    if desc.pixel_format == {
    case .Depth32FloatStencil8;
        view_info.subresourceRange.aspectMask = .DEPTH_BIT | .STENCIL_BIT;
    case .Depth32Float;
        view_info.subresourceRange.aspectMask = .DEPTH_BIT;
    case .Stencil8;
        view_info.subresourceRange.aspectMask = .STENCIL_BIT;
    case;
        view_info.subresourceRange.aspectMask = .COLOR_BIT;
    }

    view_info.subresourceRange.baseMipLevel = desc.first_mipmap_level;
    view_info.subresourceRange.levelCount = desc.num_mipmap_levels;
    view_info.subresourceRange.baseArrayLayer = desc.first_array_layer;
    view_info.subresourceRange.layerCount = desc.num_array_layers;

    image_view : VkImageView;
    if vkCreateImageView(g_gfx_context.device, *view_info, g_vk_alloc_callbacks, *image_view) != .SUCCESS {
        return .{};
    }

    SetDebugName(image_view, TPrint("Image View '%'", name));

    return .{image=texture.image, image_view=image_view, allocation=texture.allocation, desc=MakeGfxTextureAndViewDesc(texture.desc, desc)};
}

DestroyGfxTextureView :: (texture : *GfxTexture) {
    LogSectionScope(*Log_Vulkan);

    vkDestroyImageView(g_gfx_context.device, texture.image_view, g_vk_alloc_callbacks);
    texture.* = .{};
}

QueueDestroyGfxTextureView :: (texture : *GfxTexture) {
    collector := *g_gfx_context.texture_view_collectors[g_gfx_context.frame_in_flight];
    AddGarbage(collector, texture);
    texture.* = .{};
}

GfxSamplerFilter :: enum u8 {
    Nearest;
    Linear;
}

MakeVkFilter :: inline (filter : GfxSamplerFilter) -> VkFilter {
    if #complete filter == {
    case .Nearest; return .NEAREST;
    case .Linear; return .LINEAR;
    }
}

MakeVkSamplerMipmapMode :: inline (filter : GfxSamplerFilter) -> VkSamplerMipmapMode {
    if #complete filter == {
    case .Nearest; return .NEAREST;
    case .Linear; return .LINEAR;
    }
}

GfxSamplerAddressMode :: enum u8 {
    Repeat;
    ClampToEdge;
    ClampToBorder;
    MirrorRepeat;
    MirrorClampToEdge;
}

MakeVkSamplerAddressMode :: (mode : GfxSamplerAddressMode) -> VkSamplerAddressMode {
    if #complete mode == {
    case .Repeat;            return .REPEAT;
    case .ClampToEdge;       return .CLAMP_TO_EDGE;
    case .ClampToBorder;     return .CLAMP_TO_BORDER;
    case .MirrorRepeat;      return .MIRRORED_REPEAT;
    case .MirrorClampToEdge; return .MIRROR_CLAMP_TO_EDGE;
    }
}

GfxSamplerBorderColor :: enum u8 {
    Transparent;
    OpaqueBlack;
    OpaqueWhite;
}

MakeVkBorderColor :: (color : GfxSamplerBorderColor) -> VkBorderColor {
    if #complete color == {
    case .Transparent; return .FLOAT_TRANSPARENT_BLACK;
    case .OpaqueBlack; return .FLOAT_OPAQUE_BLACK;
    case .OpaqueWhite; return .FLOAT_OPAQUE_WHITE;
    }
}

GfxSamplerDesc :: struct {
    min_filter : GfxSamplerFilter = .Nearest;
    mag_filter : GfxSamplerFilter = .Nearest;
    mipmap_filter : GfxSamplerFilter = .Nearest;
    u_address_mode : GfxSamplerAddressMode = .ClampToEdge;
    v_address_mode : GfxSamplerAddressMode = .ClampToEdge;
    w_address_mode : GfxSamplerAddressMode = .ClampToEdge;
    border_color : GfxSamplerBorderColor;
    compare_op : GfxCompareOp = .None;
    anisotropy_enabled := false;
    max_anisotropy : float;
    mip_lod_bias := 0.0;
    min_lod := 0.0;
    max_lod := F32_Inf;
}

GfxSampler :: struct {
    sampler : VkSampler;
    desc : GfxSamplerDesc;
}

IsNull :: inline (sampler : *GfxSampler) -> bool {
    return sampler == null || sampler.sampler == VK_NULL_HANDLE;
}

CreateGfxSampler :: (name : string, desc : GfxSamplerDesc) -> GfxSampler {
    LogSectionScope(*Log_Vulkan);

    create_info : VkSamplerCreateInfo;
    create_info.minFilter = MakeVkFilter(desc.min_filter);
    create_info.magFilter = MakeVkFilter(desc.mag_filter);
    create_info.mipmapMode = MakeVkSamplerMipmapMode(desc.mipmap_filter);
    create_info.mipLodBias = desc.mip_lod_bias;
    create_info.minLod = desc.min_lod;
    create_info.maxLod = desc.max_lod;
    create_info.addressModeU = MakeVkSamplerAddressMode(desc.u_address_mode);
    create_info.addressModeV = MakeVkSamplerAddressMode(desc.v_address_mode);
    create_info.addressModeW = MakeVkSamplerAddressMode(desc.w_address_mode);
    if desc.compare_op != .None {
        create_info.compareEnable = VK_TRUE;
        create_info.compareOp = MakeVkCompareOp(desc.compare_op);
    }
    create_info.anisotropyEnable = xx desc.anisotropy_enabled;
    create_info.maxAnisotropy = desc.max_anisotropy;
    create_info.borderColor = MakeVkBorderColor(desc.border_color);

    sampler : VkSampler;
    if vkCreateSampler(g_gfx_context.device, *create_info, g_vk_alloc_callbacks, *sampler) != .SUCCESS {
        return .{};
    }

    SetDebugName(sampler, TPrint("Sampler '%'", name));

    return .{sampler=sampler, desc=desc};
}

DestroyGfxSampler :: (sampler : *GfxSampler) {
    LogSectionScope(*Log_Vulkan);

    vkDestroySampler(g_gfx_context.device, sampler.sampler, g_vk_alloc_callbacks);
    sampler.* = .{};
}

QueueDestroyGfxSampler :: (sampler : *GfxSampler) {
    collector := *g_gfx_context.sampler_collectors[g_gfx_context.frame_in_flight];
    AddGarbage(collector, sampler);
    sampler.* = .{};
}

BeginGfxDebugMarker :: (cmd_buffer : *GfxCommandBuffer, name : string) {
    LogSectionScope(*Log_Vulkan);

    if !g_gfx_context.vkCmdBeginDebugUtilsLabelEXT || !g_gfx_context.vkCmdEndDebugUtilsLabelEXT {
        return;
    }

    label : VkDebugUtilsLabelEXT;
    label.pLabelName = CStringClone(name ,, Temp);
    g_gfx_context.vkCmdBeginDebugUtilsLabelEXT(cmd_buffer.cmd_buffer, *label);
}

EndGfxDebugMarker :: (cmd_buffer : *GfxCommandBuffer) {
    LogSectionScope(*Log_Vulkan);

    if !g_gfx_context.vkCmdBeginDebugUtilsLabelEXT || !g_gfx_context.vkCmdEndDebugUtilsLabelEXT {
        return;
    }

    g_gfx_context.vkCmdEndDebugUtilsLabelEXT(cmd_buffer.cmd_buffer);
}

BeginGfxDebugMarker :: (name : string) {
    LogSectionScope(*Log_Vulkan);

    if !g_gfx_context.vkQueueBeginDebugUtilsLabelEXT || !g_gfx_context.vkQueueEndDebugUtilsLabelEXT {
        return;
    }

    label : VkDebugUtilsLabelEXT;
    label.pLabelName = CStringClone(name ,, Temp);
    g_gfx_context.vkQueueBeginDebugUtilsLabelEXT(g_gfx_context.general_purpose_queue, *label);
}

EndGfxDebugMarker :: () {
    LogSectionScope(*Log_Vulkan);

    if !g_gfx_context.vkQueueBeginDebugUtilsLabelEXT || !g_gfx_context.vkQueueEndDebugUtilsLabelEXT {
        return;
    }

    g_gfx_context.vkQueueEndDebugUtilsLabelEXT(g_gfx_context.general_purpose_queue);
}

GfxAttachmentLoadOp :: enum {
    Load;
    Clear;
    DontCare;
}

MakeVkAttachmentLoadOp :: inline (op : GfxAttachmentLoadOp) -> VkAttachmentLoadOp {
    if #complete op == {
    case .Load;     return .LOAD;
    case .Clear;    return .CLEAR;
    case .DontCare; return .DONT_CARE;
    }
}

GfxAttachmentStoreOp :: enum {
    Store;
    DontCare;
}

MakeVkAttachmentStoreOp :: inline (op : GfxAttachmentStoreOp) -> VkAttachmentStoreOp {
    if #complete op == {
    case .Store;    return .STORE;
    case .DontCare; return .DONT_CARE;
    }
}

GfxAttachment :: struct {
    texture : *GfxTexture;
    resolve_texture : *GfxTexture;
    load_op : GfxAttachmentLoadOp = .Load;
    store_op : GfxAttachmentStoreOp = .Store;
}

GfxColorAttachment :: struct {
    #as using _ : GfxAttachment;
    clear_value : union {
        float4 : [4]float;
        int4   : [4]s32;
        uint4  : [4]u32;
    }
}

GfxDepthAttachment :: struct {
    #as using _ : GfxAttachment;
    clear_value : float;
}

GfxStencilAttachment :: struct {
    #as using _ : GfxAttachment;
    clear_value : u32;
}

GfxRenderPassDesc :: struct {
    num_color_attachments : u32;
    num_layers : u32 = 1;

    color_attachments : [Gfx_Max_Color_Attachments]GfxColorAttachment;
    depth_attachment : GfxDepthAttachment;
    stencil_attachment : GfxStencilAttachment;
}

AddColorAttachment :: (
    pass_desc : *GfxRenderPassDesc,
    texture : *GfxTexture,
    resolve_texture : *GfxTexture = null,
    load_op : GfxAttachmentLoadOp = .Load,
    store_op : GfxAttachmentStoreOp = .Store
) {
    Assert(pass_desc.num_color_attachments < Gfx_Max_Color_Attachments, "Too many color attachments");

    pass_desc.color_attachments[pass_desc.num_color_attachments] = .{
        texture=texture,
        resolve_texture=resolve_texture,
        load_op=load_op,
        store_op=store_op
    };
    pass_desc.num_color_attachments += 1;
}

AddDepthAttachment :: (
    pass_desc : *GfxRenderPassDesc,
    texture : *GfxTexture,
    resolve_texture : *GfxTexture = null,
    load_op : GfxAttachmentLoadOp = .Load,
    store_op : GfxAttachmentStoreOp = .Store
) {
    Assert(pass_desc.depth_attachment.texture == null, "Depth attachment is already set");

    pass_desc.depth_attachment = .{texture=texture, resolve_texture=resolve_texture, load_op=load_op, store_op=store_op};
}

AddStencilAttachment :: (
    pass_desc : *GfxRenderPassDesc,
    texture : *GfxTexture,
    resolve_texture : *GfxTexture,
    load_op : GfxAttachmentLoadOp = .Load,
    store_op : GfxAttachmentStoreOp = .Store
) {
    Assert(pass_desc.depth_attachment.texture == null, "Stencil attachment is already set");

    pass_desc.stencil_attachment = .{texture=texture, resolve_texture=resolve_texture, load_op=load_op, store_op=store_op};
}

ClearColor :: inline (pass_desc : *GfxRenderPassDesc, index : u32, value : Vec4f) {
    Assert(index < pass_desc.num_color_attachments, "No color attachment at index %", index);

    pass_desc.color_attachments[index].load_op = .Clear;
    pass_desc.color_attachments[index].clear_value.float4[0] = value.r;
    pass_desc.color_attachments[index].clear_value.float4[1] = value.g;
    pass_desc.color_attachments[index].clear_value.float4[2] = value.b;
    pass_desc.color_attachments[index].clear_value.float4[3] = value.a;
}

ClearColor :: inline (pass_desc : *GfxRenderPassDesc, index : u32, value : Vec4i) {
    Assert(index < pass_desc.num_color_attachments, "No color attachment at index %", index);

    pass_desc.color_attachments[index].load_op = .Clear;
    pass_desc.color_attachments[index].clear_value.int4[0] = value.r;
    pass_desc.color_attachments[index].clear_value.int4[1] = value.g;
    pass_desc.color_attachments[index].clear_value.int4[2] = value.b;
    pass_desc.color_attachments[index].clear_value.int4[3] = value.a;
}

ClearColor :: inline (pass_desc : *GfxRenderPassDesc, index : u32, value : Vec4u) {
    Assert(index < pass_desc.num_color_attachments, "No color attachment at index %", index);

    pass_desc.color_attachments[index].load_op = .Clear;
    pass_desc.color_attachments[index].clear_value.uint4[0] = value.r;
    pass_desc.color_attachments[index].clear_value.uint4[1] = value.g;
    pass_desc.color_attachments[index].clear_value.uint4[2] = value.b;
    pass_desc.color_attachments[index].clear_value.uint4[3] = value.a;
}

ClearDepth :: inline (pass_desc : *GfxRenderPassDesc, value : float) {
    pass_desc.depth_attachment.load_op = .Clear;
    pass_desc.depth_attachment.clear_value = value;
}

ClearStencil :: inline (pass_desc : *GfxRenderPassDesc, value : u32) {
    pass_desc.stencil_attachment.load_op = .Clear;
    pass_desc.stencil_attachment.clear_value = value;
}

GfxRenderPass :: struct {
    desc : GfxRenderPassDesc;
    cmd_buffer : *GfxCommandBuffer;

    current_pipeline : *GfxGraphicsPipeline;
}

BeginGfxRenderPass :: (cmd_buffer : *GfxCommandBuffer, name : string, desc : GfxRenderPassDesc) -> GfxRenderPass {
    LogSectionScope(*Log_Vulkan);

    w, h : u32;

    color_attachments : [Gfx_Max_Color_Attachments]VkRenderingAttachmentInfo;
    if desc.num_color_attachments > 0 {
        for i : 0..desc.num_color_attachments - 1 {
            Assert(!IsNull(desc.color_attachments[i].texture), "Color attachment % is null", i);

            w = desc.color_attachments[i].texture.desc.width;
            h = desc.color_attachments[i].texture.desc.height;

            color_attachments[i].imageView = desc.color_attachments[i].texture.image_view;
            color_attachments[i].imageLayout = .ATTACHMENT_OPTIMAL_KHR;

            if !IsNull(desc.color_attachments[i].resolve_texture) {
                color_attachments[i].resolveMode = .AVERAGE_BIT;
                color_attachments[i].resolveImageView = desc.color_attachments[i].resolve_texture.image_view;
                color_attachments[i].resolveImageLayout = .ATTACHMENT_OPTIMAL_KHR;
            }

            color_attachments[i].loadOp = MakeVkAttachmentLoadOp(desc.color_attachments[i].load_op);
            color_attachments[i].storeOp = MakeVkAttachmentStoreOp(desc.color_attachments[i].store_op);
            color_attachments[i].clearValue.color.int32[0] = desc.color_attachments[i].clear_value.int4[0];
            color_attachments[i].clearValue.color.int32[1] = desc.color_attachments[i].clear_value.int4[1];
            color_attachments[i].clearValue.color.int32[2] = desc.color_attachments[i].clear_value.int4[2];
            color_attachments[i].clearValue.color.int32[3] = desc.color_attachments[i].clear_value.int4[3];
        }
    }

    depth_attachment : VkRenderingAttachmentInfo;
    if !IsNull(desc.depth_attachment.texture) {
        w = desc.depth_attachment.texture.desc.width;
        h = desc.depth_attachment.texture.desc.height;

        depth_attachment.imageView = desc.depth_attachment.texture.image_view;
        depth_attachment.imageLayout = .ATTACHMENT_OPTIMAL_KHR;

        if !IsNull(desc.depth_attachment.resolve_texture) {
            depth_attachment.resolveMode = .AVERAGE_BIT;
            depth_attachment.resolveImageView = desc.depth_attachment.resolve_texture.image_view;
            depth_attachment.resolveImageLayout = .ATTACHMENT_OPTIMAL_KHR;
        }

        depth_attachment.loadOp = MakeVkAttachmentLoadOp(desc.depth_attachment.load_op);
        depth_attachment.storeOp = MakeVkAttachmentStoreOp(desc.depth_attachment.store_op);
        depth_attachment.clearValue.depthStencil.depth = desc.depth_attachment.clear_value;
    }

    stencil_attachment : VkRenderingAttachmentInfo;
    if !IsNull(desc.stencil_attachment.texture) {
        w = desc.stencil_attachment.texture.desc.width;
        h = desc.stencil_attachment.texture.desc.height;

        stencil_attachment.imageView = desc.stencil_attachment.texture.image_view;
        stencil_attachment.imageLayout = .ATTACHMENT_OPTIMAL_KHR;

        if !IsNull(desc.stencil_attachment.resolve_texture) {
            stencil_attachment.resolveMode = .AVERAGE_BIT;
            stencil_attachment.resolveImageView = desc.stencil_attachment.resolve_texture.image_view;
            stencil_attachment.resolveImageLayout = .ATTACHMENT_OPTIMAL_KHR;
        }

        stencil_attachment.loadOp = MakeVkAttachmentLoadOp(desc.stencil_attachment.load_op);
        stencil_attachment.storeOp = MakeVkAttachmentStoreOp(desc.stencil_attachment.store_op);
        stencil_attachment.clearValue.depthStencil.stencil = desc.stencil_attachment.clear_value;
    }

    render_info : VkRenderingInfo;
    render_info.layerCount = desc.num_layers;
    render_info.colorAttachmentCount = desc.num_color_attachments;
    render_info.pColorAttachments = color_attachments.data;
    render_info.pDepthAttachment = ifx !IsNull(desc.depth_attachment.texture) then *depth_attachment;
    render_info.pStencilAttachment = ifx !IsNull(desc.stencil_attachment.texture) then *stencil_attachment;
    render_info.renderArea.extent = .{width=xx w, height=xx h};

    BeginGfxDebugMarker(cmd_buffer, name);
    vkCmdBeginRendering(cmd_buffer.cmd_buffer, *render_info);

    return .{desc=desc, cmd_buffer=cmd_buffer};
}

EndGfxRenderPass :: (pass : *GfxRenderPass) {
    LogSectionScope(*Log_Vulkan);

    vkCmdEndRendering(pass.cmd_buffer.cmd_buffer);
    EndGfxDebugMarker(pass.cmd_buffer);

    AddBarrier(pass.cmd_buffer);
}

BindGraphicsPipeline :: (pass : *GfxRenderPass, pipeline : *GfxGraphicsPipeline) {
    pass.current_pipeline = pipeline;
    vkCmdBindPipeline(pass.cmd_buffer.cmd_buffer, .GRAPHICS, pipeline.pipeline);
}

BindGraphicsBindingSet :: (pass : *GfxRenderPass, index : u32, set : *GfxBindingSet) {
    Assert(pass.current_pipeline != null, "Render pass has no pipeline bound yet. Use BindGraphicsBindingSet on a command buffer and specify pipeline layout or bind a pipeline first");

    BindGraphicsBindingSet(pass.cmd_buffer, *pass.current_pipeline.layout, index, set);
}

GfxViewport :: struct {
    top_left_x : float;
    top_left_y : float;
    width : float;
    height : float;
    min_depth : float = 0;
    max_depth : float = 1;
}

SetViewport :: (pass : *GfxRenderPass, viewport : GfxViewport) {
    vk_viewport := VkViewport.{x=viewport.top_left_x, y=viewport.top_left_y, width=viewport.width, height=viewport.height, minDepth=viewport.min_depth, maxDepth=viewport.max_depth};
    vkCmdSetViewport(pass.cmd_buffer.cmd_buffer, 0, 1, *vk_viewport);
}

SetScissor :: (pass : *GfxRenderPass, rect : Recti) {
    vk_scissor := VkRect2D.{offset=.{rect.x, rect.y}, extent=.{xx rect.w, xx rect.h}};
    vkCmdSetScissor(pass.cmd_buffer.cmd_buffer, 0, 1, *vk_scissor);
}

SetStencilReference :: (pass : *GfxRenderPass, front_value : u32, back_value : u32) {
    vkCmdSetStencilReference(pass.cmd_buffer.cmd_buffer, .FACE_FRONT_BIT, front_value);
    vkCmdSetStencilReference(pass.cmd_buffer.cmd_buffer, .FACE_BACK_BIT, back_value);
}

SetBlendConstant :: (pass : *GfxRenderPass, color : Vec4f) {
    vkCmdSetBlendConstants(pass.cmd_buffer.cmd_buffer, xx *color);
}

BindVertexBuffer :: (pass : *GfxRenderPass, binding : u32, buffer : *GfxBuffer, offset : u64 = 0) {
    vkCmdBindVertexBuffers(pass.cmd_buffer.cmd_buffer, binding, 1, *buffer.buffer, *offset);
}

BindGraphicsBindingSet :: (cmd_buffer : *GfxCommandBuffer, layout : *GfxPipelineLayout, index : u32, set : *GfxBindingSet) {
    vkCmdBindDescriptorSets(cmd_buffer.cmd_buffer, .GRAPHICS, layout.layout, index, 1, *set.set, 0, null);
}

BindComputeBindingSet :: (cmd_buffer : *GfxCommandBuffer, layout : *GfxPipelineLayout, index : u32, set : *GfxBindingSet) {
    vkCmdBindDescriptorSets(cmd_buffer.cmd_buffer, .COMPUTE, layout.layout, index, 1, *set.set, 0, null);
}

GfxIndexType :: enum {
    UInt16;
    UInt32;
}

BindIndexBuffer :: (pass : *GfxRenderPass, type : GfxIndexType, buffer : *GfxBuffer, offset : u64 = 0) {
    vk_index_type : VkIndexType;
    if #complete type == {
    case .UInt16; vk_index_type = .UINT16;
    case .UInt32; vk_index_type = .UINT32;
    }

    vkCmdBindIndexBuffer(pass.cmd_buffer.cmd_buffer, buffer.buffer, offset, vk_index_type);
}

Draw :: (
    pass : *GfxRenderPass,
    vertex_count : u32,
    instance_count : u32,
    base_vertex : u32 = 0,
    base_instance : u32 = 0
) {
    vkCmdDraw(pass.cmd_buffer.cmd_buffer, vertex_count, instance_count, base_vertex, base_instance);
}

DrawIndexed :: (
    pass : *GfxRenderPass,
    index_count : u32,
    instance_count : u32,
    base_index : u32 = 0,
    base_vertex : u32 = 0,
    base_instance : u32 = 0
) {
    vkCmdDrawIndexed(pass.cmd_buffer.cmd_buffer, index_count, instance_count, base_index, xx base_vertex, base_instance);
}

GfxComputePass :: struct {
    name : string;
    cmd_buffer : *GfxCommandBuffer;
    current_pipeline : *GfxComputePipeline;
}

BeginGfxComputePass :: (cmd_buffer : *GfxCommandBuffer, name : string) -> GfxComputePass {
    LogSectionScope(*Log_Vulkan);

    BeginGfxDebugMarker(cmd_buffer, name);

    return .{name=name, cmd_buffer=cmd_buffer};
}

EndGfxComputePass :: (pass : *GfxComputePass) {
    LogSectionScope(*Log_Vulkan);

    EndGfxDebugMarker(pass.cmd_buffer);

    AddBarrier(pass.cmd_buffer);
}

BindComputePipeline :: (pass : *GfxComputePass, pipeline : *GfxComputePipeline) {
    pass.current_pipeline = pipeline;
    vkCmdBindPipeline(pass.cmd_buffer.cmd_buffer, .COMPUTE, pipeline.pipeline);
}

BindComputeBindingSet :: (pass : *GfxComputePass, index : u32, set : *GfxBindingSet) {
    Assert(pass.current_pipeline != null, "Render pass has no pipeline bound yet. Use BindComputeBindingSet on a command buffer and specify pipeline layout or bind a pipeline first");

    BindComputeBindingSet(pass.cmd_buffer, *pass.current_pipeline.layout, index, set);
}

Dispatch :: (pass : *GfxComputePass, num_groups_x : u32, num_groups_y : u32, num_groups_z : u32) {
    vkCmdDispatch(pass.cmd_buffer.cmd_buffer, num_groups_x, num_groups_y, num_groups_z);
}

GfxCopyPass :: struct {
    name : string;
    cmd_buffer : *GfxCommandBuffer;
}

BeginGfxCopyPass :: (cmd_buffer : *GfxCommandBuffer, name : string) -> GfxCopyPass {
    LogSectionScope(*Log_Vulkan);

    BeginGfxDebugMarker(cmd_buffer, name);

    return .{name=name, cmd_buffer=cmd_buffer};
}

EndGfxCopyPass :: (pass : *GfxCopyPass) {
    LogSectionScope(*Log_Vulkan);

    EndGfxDebugMarker(pass.cmd_buffer);

    AddBarrier(pass.cmd_buffer);
}

CopyBufferToTexture :: (pass : *GfxCopyPass, src_buffer : *GfxBuffer, dst_texture : *GfxTexture) {
    copy : VkBufferImageCopy;
    copy.imageSubresource = MakeVkImageSubresourceLayers(dst_texture.desc, 0);
    copy.imageExtent = .{dst_texture.desc.width, dst_texture.desc.height, dst_texture.desc.depth};

    vkCmdCopyBufferToImage(pass.cmd_buffer.cmd_buffer, src_buffer.buffer, dst_texture.image, .TRANSFER_DST_OPTIMAL, 1, *copy);
}

CopyTextureToBuffer :: (pass : *GfxCopyPass, src_texture : *GfxTexture, dst_buffer : *GfxBuffer) {
    copy : VkBufferImageCopy;
    copy.imageSubresource = MakeVkImageSubresourceLayers(src_texture.desc, 0);
    copy.imageExtent = .{src_texture.desc.width, src_texture.desc.height, src_texture.desc.depth};

    vkCmdCopyImageToBuffer(pass.cmd_buffer.cmd_buffer, src_texture.image, .TRANSFER_SRC_OPTIMAL, dst_buffer.buffer, 1, *copy);
}

GenerateMipmaps :: (pass : *GfxCopyPass, texture : *GfxTexture, old_layout : GfxTextureLayout, new_layout : GfxTextureLayout) {
    if texture.desc.num_mipmap_levels < 2 {
        AddTextureBarrier(pass.cmd_buffer, old_layout, new_layout, texture);
        return;
    }

    src_mip_width := cast(s32, texture.desc.width);
    src_mip_height := cast(s32, texture.desc.height);
    for i : 0..texture.desc.num_mipmap_levels - 2 {
        source_old_layout := ifx i == 0 then old_layout else .TransferDst;

        barriers : [2]VkImageMemoryBarrier;
        barriers[0].srcAccessMask = MakeVkAccessFlags(.AllWrites | .AllReads);
        barriers[0].dstAccessMask = MakeVkAccessFlags(.AllWrites | .AllReads);
        barriers[0].oldLayout = MakeVkImageLayout(source_old_layout);
        barriers[0].newLayout = MakeVkImageLayout(.TransferSrc);
        barriers[0].srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        barriers[0].dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        barriers[0].image = texture.image;
        barriers[0].subresourceRange = MakeVkImageSubresourceRange(texture.desc);
        barriers[0].subresourceRange.baseMipLevel = i;
        barriers[0].subresourceRange.levelCount = 1;

        barriers[1].srcAccessMask = MakeVkAccessFlags(.AllWrites | .AllReads);
        barriers[1].dstAccessMask = MakeVkAccessFlags(.AllWrites | .AllReads);
        barriers[1].oldLayout = MakeVkImageLayout(.Undefined);
        barriers[1].newLayout = MakeVkImageLayout(.TransferDst);
        barriers[1].srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        barriers[1].dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        barriers[1].image = texture.image;
        barriers[1].subresourceRange = MakeVkImageSubresourceRange(texture.desc);
        barriers[1].subresourceRange.baseMipLevel = i + 1;
        barriers[1].subresourceRange.levelCount = 1;

        src_stages := MakeVkPipelineStageFlags(ifx i == 0 then .AllCommands else .AllTransfer);
        dst_stages := MakeVkPipelineStageFlags(.AllTransfer);
        vkCmdPipelineBarrier(
            pass.cmd_buffer.cmd_buffer,
            src_stages, dst_stages,
            dependencyFlags=0,
            memoryBarrierCount=0, pMemoryBarriers=null,
            bufferMemoryBarrierCount=0, pBufferMemoryBarriers=null,
            imageMemoryBarrierCount=xx barriers.count, pImageMemoryBarriers=barriers.data,
        );

        blit : VkImageBlit;
        blit.srcSubresource = MakeVkImageSubresourceLayers(texture.desc, i);
        blit.dstSubresource = MakeVkImageSubresourceLayers(texture.desc, i + 1);
        blit.srcOffsets[1] = .{src_mip_width, src_mip_height, 1};
        blit.dstOffsets[1] = .{Max(src_mip_width / 2, 1), Max(src_mip_height / 2, 1), 1};

        vkCmdBlitImage(pass.cmd_buffer.cmd_buffer, texture.image, .TRANSFER_SRC_OPTIMAL, texture.image, .TRANSFER_DST_OPTIMAL, 1, *blit, .LINEAR);

        src_mip_width /= 2;
        src_mip_height /= 2;
    }

    // Transition all mipmap levels to new layout
    barriers : [2]VkImageMemoryBarrier;
    barriers[0].srcAccessMask = MakeVkAccessFlags(.AllWrites | .AllReads);
    barriers[0].dstAccessMask = MakeVkAccessFlags(.AllWrites | .AllReads);
    barriers[0].oldLayout = MakeVkImageLayout(.TransferSrc);
    barriers[0].newLayout = MakeVkImageLayout(new_layout);
    barriers[0].srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barriers[0].dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barriers[0].image = texture.image;
    barriers[0].subresourceRange = MakeVkImageSubresourceRange(texture.desc);
    barriers[0].subresourceRange.baseMipLevel = 0;
    barriers[0].subresourceRange.levelCount = texture.desc.num_mipmap_levels - 1;

    barriers[1].srcAccessMask = MakeVkAccessFlags(.AllWrites | .AllReads);
    barriers[1].dstAccessMask = MakeVkAccessFlags(.AllWrites | .AllReads);
    barriers[1].oldLayout = MakeVkImageLayout(.TransferDst);
    barriers[1].newLayout = MakeVkImageLayout(new_layout);
    barriers[1].srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barriers[1].dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barriers[1].image = texture.image;
    barriers[1].subresourceRange = MakeVkImageSubresourceRange(texture.desc);
    barriers[1].subresourceRange.baseMipLevel = texture.desc.num_mipmap_levels - 1;
    barriers[1].subresourceRange.levelCount = 1;

    src_stages := MakeVkPipelineStageFlags(.AllTransfer);
    dst_stages := MakeVkPipelineStageFlags(.AllCommands);
    vkCmdPipelineBarrier(
        pass.cmd_buffer.cmd_buffer,
        src_stages, dst_stages,
        dependencyFlags=0,
        memoryBarrierCount=0, pMemoryBarriers=null,
        bufferMemoryBarrierCount=0, pBufferMemoryBarriers=null,
        imageMemoryBarrierCount=xx barriers.count, pImageMemoryBarriers=barriers.data,
    );
}

// More fine grained sync points can be added and are supported by Vulkan
GfxBarrierSyncPointFlags :: enum_flags {
    AllGraphics;
    AllCompute;
    AllTransfer;
    AllCommands;
}

// More fine grained access flags can be added and are supported by Vulkan
GfxBarrierAccessFlags :: enum_flags {
    AllWrites;
    AllReads;
}

MakeVkPipelineStageFlags :: inline (sync_point : GfxBarrierSyncPointFlags) -> VkPipelineStageFlags {
    result : VkPipelineStageFlags;
    if sync_point & .AllGraphics {
        result |= .ALL_GRAPHICS_BIT;
    }
    if sync_point & .AllCompute {
        result |= .COMPUTE_SHADER_BIT;
    }
    if sync_point & .AllTransfer {
        result |= .TRANSFER_BIT;
    }
    if sync_point & .AllCommands {
        result |= .ALL_COMMANDS_BIT;
    }

    return result;
}

MakeVkAccessFlags :: inline (access : GfxBarrierAccessFlags) -> VkAccessFlags {
    result : VkAccessFlags;
    if access & .AllReads {
        result |= .MEMORY_READ_BIT;
    }
    if access & .AllWrites {
        result |= .MEMORY_WRITE_BIT;
    }

    return result;
}

AddBarrier :: (
    cmd_buffer : *GfxCommandBuffer,
    src_sync_points : GfxBarrierSyncPointFlags, dst_sync_points : GfxBarrierSyncPointFlags
) {
    src_stages := ifx src_sync_points != 0 then MakeVkPipelineStageFlags(src_sync_points) else .TOP_OF_PIPE_BIT;
    dst_stages := ifx dst_sync_points != 0 then MakeVkPipelineStageFlags(dst_sync_points) else .BOTTOM_OF_PIPE_BIT;
    vkCmdPipelineBarrier(
        cmd_buffer.cmd_buffer,
        src_stages, dst_stages,
        dependencyFlags=0,
        memoryBarrierCount=0, pMemoryBarriers=null,
        bufferMemoryBarrierCount=0, pBufferMemoryBarriers=null,
        imageMemoryBarrierCount=0, pImageMemoryBarriers=null,
    );
}

AddBarrier :: inline (cmd_buffer : *GfxCommandBuffer) {
    AddBarrier(cmd_buffer, .AllCommands, .AllCommands);
}

AddMemoryBarrier :: (
    cmd_buffer : *GfxCommandBuffer,
    src_sync_points : GfxBarrierSyncPointFlags, src_accesses : GfxBarrierAccessFlags,
    dst_sync_points : GfxBarrierSyncPointFlags, dst_accesses : GfxBarrierAccessFlags
) {
    barrier : VkMemoryBarrier;
    barrier.srcAccessMask = MakeVkAccessFlags(src_accesses);
    barrier.dstAccessMask = MakeVkAccessFlags(dst_accesses);

    src_stages := ifx src_sync_points != 0 then MakeVkPipelineStageFlags(src_sync_points) else .TOP_OF_PIPE_BIT;
    dst_stages := ifx dst_sync_points != 0 then MakeVkPipelineStageFlags(dst_sync_points) else .BOTTOM_OF_PIPE_BIT;
    vkCmdPipelineBarrier(
        cmd_buffer.cmd_buffer,
        src_stages, dst_stages,
        dependencyFlags=0,
        memoryBarrierCount=1, pMemoryBarriers=*barrier,
        bufferMemoryBarrierCount=0, pBufferMemoryBarriers=null,
        imageMemoryBarrierCount=0, pImageMemoryBarriers=null,
    );
}

GfxTextureLayout :: enum {
    Undefined;
    General;
    TransferSrc;
    TransferDst;
    ShaderReadOnly;
    ColorAttachment;
    DepthStencilAttachment;
    PresentSrc;
}

MakeVkImageLayout :: inline (layout : GfxTextureLayout) -> VkImageLayout {
    if #complete layout == {
    case .Undefined;              return .UNDEFINED;
    case .General;                return .GENERAL;
    case .TransferSrc;            return .TRANSFER_SRC_OPTIMAL;
    case .TransferDst;            return .TRANSFER_DST_OPTIMAL;
    case .ShaderReadOnly;         return .SHADER_READ_ONLY_OPTIMAL ;
    case .ColorAttachment;        return .COLOR_ATTACHMENT_OPTIMAL;
    case .DepthStencilAttachment; return .DEPTH_STENCIL_ATTACHMENT_OPTIMAL;
    case .PresentSrc;             return .PRESENT_SRC_KHR;
    }
}

AddTextureBarrier :: (
    cmd_buffer : *GfxCommandBuffer,
    src_sync_points : GfxBarrierSyncPointFlags, src_accesses : GfxBarrierAccessFlags,
    dst_sync_points : GfxBarrierSyncPointFlags, dst_accesses : GfxBarrierAccessFlags,
    old_layout : GfxTextureLayout, new_layout : GfxTextureLayout,
    texture : *GfxTexture
) {
    barrier : VkImageMemoryBarrier;
    barrier.srcAccessMask = MakeVkAccessFlags(src_accesses);
    barrier.dstAccessMask = MakeVkAccessFlags(dst_accesses);
    barrier.oldLayout = MakeVkImageLayout(old_layout);
    barrier.newLayout = MakeVkImageLayout(new_layout);
    barrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barrier.image = texture.image;
    barrier.subresourceRange = MakeVkImageSubresourceRange(texture.desc);

    src_stages := ifx src_sync_points != 0 then MakeVkPipelineStageFlags(src_sync_points) else .TOP_OF_PIPE_BIT;
    dst_stages := ifx dst_sync_points != 0 then MakeVkPipelineStageFlags(dst_sync_points) else .BOTTOM_OF_PIPE_BIT;
    vkCmdPipelineBarrier(
        cmd_buffer.cmd_buffer,
        src_stages, dst_stages,
        dependencyFlags=0,
        memoryBarrierCount=0, pMemoryBarriers=null,
        bufferMemoryBarrierCount=0, pBufferMemoryBarriers=null,
        imageMemoryBarrierCount=1, pImageMemoryBarriers=*barrier,
    );
}

AddTextureBarrier :: (
    cmd_buffer : *GfxCommandBuffer,
    old_layout : GfxTextureLayout, new_layout : GfxTextureLayout,
    texture : *GfxTexture
) {
    AddTextureBarrier(
        cmd_buffer,
        .AllCommands, .AllWrites | .AllReads, .AllCommands, .AllWrites | .AllReads, old_layout,
        new_layout,
        texture
    );
}

AddTextureBarriers :: (
    cmd_buffer : *GfxCommandBuffer,
    old_layout : GfxTextureLayout, new_layout : GfxTextureLayout,
    textures : []*GfxTexture
) {
    barriers := AllocArray(VkImageMemoryBarrier, textures.count ,, Temp);
    for textures {
        barriers[it_index].sType = .IMAGE_MEMORY_BARRIER;
        barriers[it_index].pNext = null;
        barriers[it_index].srcAccessMask = .MEMORY_READ_BIT | .MEMORY_WRITE_BIT;
        barriers[it_index].dstAccessMask = .MEMORY_READ_BIT | .MEMORY_WRITE_BIT;
        barriers[it_index].oldLayout = MakeVkImageLayout(old_layout);
        barriers[it_index].newLayout = MakeVkImageLayout(new_layout);
        barriers[it_index].srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        barriers[it_index].dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        barriers[it_index].image = it.image;
        barriers[it_index].subresourceRange = MakeVkImageSubresourceRange(it.desc);
    }

    src_stages := MakeVkPipelineStageFlags(.AllCommands);
    dst_stages := MakeVkPipelineStageFlags(.AllCommands);
    vkCmdPipelineBarrier(
        cmd_buffer.cmd_buffer,
        src_stages, dst_stages,
        dependencyFlags=0,
        memoryBarrierCount=0, pMemoryBarriers=null,
        bufferMemoryBarrierCount=0, pBufferMemoryBarriers=null,
        imageMemoryBarrierCount=xx barriers.count, pImageMemoryBarriers=barriers.data,
    );
}

SetDebugName :: (obj : $T, name : string) {
    ctx := *g_gfx_context;
    if !ctx.vkSetDebugUtilsObjectNameEXT {
        return;
    }

    Object_Types :: (struct{type : Type; vk_type : VkObjectType;}).[
        .{VkPhysicalDevice, .PHYSICAL_DEVICE},
        .{VkDevice, .DEVICE},
        .{VkQueue, .QUEUE},
        .{VkSemaphore, .SEMAPHORE},
        .{VkFence, .FENCE},
        .{VkBuffer, .BUFFER},
        .{VkBufferView, .BUFFER_VIEW},
        .{VkImage, .IMAGE},
        .{VkImageView, .IMAGE_VIEW},
        .{VkShaderModule, .SHADER_MODULE},
        .{VkPipelineCache, .PIPELINE_CACHE},
        .{VkPipelineLayout, .PIPELINE_LAYOUT},
        .{VkRenderPass, .RENDER_PASS},
        .{VkPipeline, .PIPELINE},
        .{VkDescriptorSetLayout, .DESCRIPTOR_SET_LAYOUT},
        .{VkSampler, .SAMPLER},
        .{VkDescriptorPool, .DESCRIPTOR_POOL},
        .{VkDescriptorSet, .DESCRIPTOR_SET},
        .{VkFramebuffer, .FRAMEBUFFER},
        .{VkCommandPool, .COMMAND_POOL},
        .{VkCommandBuffer, .COMMAND_BUFFER},
        .{VkSurfaceKHR, .SURFACE_KHR},
        .{VkSwapchainKHR, .SWAPCHAIN_KHR},
        .{VkDebugReportCallbackEXT, .DEBUG_REPORT_CALLBACK_EXT},
        .{VkDisplayKHR, .DISPLAY_KHR},
        .{VkDisplayModeKHR, .DISPLAY_MODE_KHR},
        .{VkValidationCacheEXT, .VALIDATION_CACHE_EXT},
    ];

    name_info : VkDebugUtilsObjectNameInfoEXT;
    name_info.objectType = #run -> VkObjectType {
        for Object_Types {
            if it.type == T {
                return it.vk_type;
            }
        }

        Panic("Unhandled object type %", T);
        return .UNKNOWN;
    }

    name_info.objectHandle = xx obj;
    name_info.pObjectName = CStringClone(name ,, Temp);
    ctx.vkSetDebugUtilsObjectNameEXT(ctx.device, *name_info);
}

VulkanDebugCallback :: (
    severity : VkDebugUtilsMessageSeverityFlagBitsEXT,
    type : VkDebugUtilsMessageTypeFlagsEXT,
    callback_data : *VkDebugUtilsMessengerCallbackDataEXT,
    user_data : *void
) -> VkBool32 #c_call {
    if callback_data.messageIdNumber == {
    case 0xc81ad50e; // WARNING-Shader-OutputNotConsumed
        return VK_FALSE;
    }

    ctx := cast(*#Context, user_data).*;
    push_context,defer_pop ctx;

    LogSectionScope(*Log_Vulkan);

    msg := MakeString(callback_data.pMessage);
    msg=, spec, verbose := MakeVulkanDebugMessageLessVerbose(msg);

    if verbose {
        LogMessage("messageId=0x%, %", FormatIntHex(callback_data.messageIdNumber), verbose, flags=.VERBOSE_ONLY);
    }

    if severity & .ERROR_BIT_EXT {
        LogError("%\n%", msg, spec);
        #if Vulkan_Break_On_Error {
            Panic("Vulkan error");
        }
    } else if severity & .WARNING_BIT_EXT {
        LogWarning("%\n%", msg, spec);
    } else {
        LogMessage("%\n%", msg, spec);
    }

    return VK_FALSE;
}

MakeVulkanDebugMessageLessVerbose :: (msg : string) -> msg : string, spec : string, verbose : string {
    i := find_index_from_left(msg, "MessageID = 0x");
    if i < 0 {
        return msg, "", "";
    }

    result := StringAdvance(msg, i + "MessageID = 0x".count);
    _, _, result = Basic.string_to_int(result, base=16);
    result = StringAdvance(result, " | ".count);

    spec : string;

    i2 := find_index_from_left(result, "The Vulkan spec states: ");
    if i2 >= 0 {
        spec = StringAdvance(result, i2 + "The Vulkan spec states: ".count);
        result.count = i2;
    }

    verbose := msg;
    verbose.count = i;

    return result, spec, verbose;
}
