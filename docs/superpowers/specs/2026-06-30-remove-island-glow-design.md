# Remove Island Glow Design

## Goal

Remove the diffuse white glow around the island in dark mode without changing its shape, border, animation, content, or light-mode depth.

## Change

Keep the existing shadow modifier and its animation values, but make the dark-mode shadow color transparent. Light mode continues to use the existing black shadow. The subtle border remains so the island shape still has a defined edge.

## Verification

Run tests, rebuild the app bundle, relaunch X Nook, and visually confirm that the diffuse white halo is gone while the island geometry remains unchanged.
