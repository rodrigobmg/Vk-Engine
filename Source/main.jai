// This file contains the entry point and engine/game loop.
// Implementation details of the engine initialization/shutdown/loop can be found in engine_main.jai
// This file is the main interface for users to add initialization and update code, as well as schedule
// entity updates that cannot be done in a dumb way and has to be done in a specific order.

#load "engine_main.jai";

UpdateWorld :: (world : *World) {
    DestroyKilledEntities(world);

    // Put your update code here
}

main :: () {
    InitEngine();
    defer TerminateEngine();

    InitAssets();
    defer CleanupAssets();

    InitEditor();
    defer CleanupEditor();

    world : World;
    defer DestroyWorld(*world);

    if g_preferences.startup_scene {
        LoadWorldFromDirectory(*world, g_preferences.startup_scene);
    }

    while !g_should_quit {
        frame_event := ProfilerBeginFrame(*g_cpu_profiler);

        EngineLoopStart();
        UpdateWorld(*world);
        UpdateEditor(*world);
        RenderFrame(*world, *g_editor_camera);

        ProfilerEndFrame(*g_cpu_profiler, frame_event);
    }
}
