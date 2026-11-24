# Controller models

The Controller Test screen's 3D controllers:

- `App/Resources/XboxController.usdz`, from "Microsoft Xbox One", shown for Xbox and every other controller.
- `App/Resources/DualSense.usdz`, from "Sony DualSense", shown for a DualSense or DualShock 4.

Both come from [CasperH2O/3DControllerModels](https://github.com/CasperH2O/3DControllerModels), released under CC0 1.0 (public domain). Thanks to CasperH2O.

## Re-exporting

```sh
git clone --depth 1 https://github.com/CasperH2O/3DControllerModels build/ctrlmodels/repo
/Applications/Blender.app/Contents/MacOS/Blender --background --disable-autoexec \
  "build/ctrlmodels/repo/Models/Microsoft Xbox One.blend" --python scripts/controller-model/export-xbox.py -- App/Resources/XboxController.usdz
/Applications/Blender.app/Contents/MacOS/Blender --background --disable-autoexec \
  "build/ctrlmodels/repo/Models/Sony DualSense.blend" --python scripts/controller-model/export-dualsense.py -- App/Resources/DualSense.usdz
```

Each export puts +X to the right, +Y towards the triggers and +Z out of the face, 2 units wide, with every button as its own part. Materials are dropped because `App/Views/ControllerScene.swift` builds its own.

## Previewing on the Mac

```sh
mkdir -p build/preview-bin
swiftc -O App/Views/ControllerScene.swift scripts/controller-model/preview/main.swift -o build/preview-bin/controller-preview
build/preview-bin/controller-preview App/Resources build/preview-out
```

This writes rest, pressed, touchpad swipe, turned and top-down PNGs of both controllers, in dark and light mode. It needs the GPU, so it renders nothing inside an agent sandbox.
