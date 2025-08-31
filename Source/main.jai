// This file contains the entry point and engine/game loop.
// Implementation details of the engine initialization/shutdown/loop can be found in engine_main.jai

#load "engine_main.jai";

UpdateWorld :: (world : *World) {
    DestroyKilledEntities(world);
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
        EngineLoopStart();
        UpdateWorld(*world);
        UpdateEditor(*world);
        RenderFrame(*world, *g_editor_camera);
    }
}
