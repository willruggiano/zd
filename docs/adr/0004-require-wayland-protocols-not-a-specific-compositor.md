# Require Wayland protocols rather than a particular compositor

Require layer-shell for the noninteractive indicator.
Require ext-data-control for background clipboard publication.
Report unsupported capabilities clearly. Do not add desktop-specific integrations as fallbacks.

The user's initial Hyprland setup is not a product dependency.
Show the indicator on all monitors without compositor-specific focus queries.
Bind the systemd user service to graphical-session.target with a PipeWire dependency.

This choice keeps the native implementation small and reusable on compositors that support these protocols.
The deliberate limit is lack of support for stock GNOME/Mutter and other compositors without the required protocols.
