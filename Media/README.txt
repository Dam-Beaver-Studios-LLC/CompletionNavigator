Textures for Completion Navigator.

Logo.tga  -- addon icon, used by the .toc IconTexture line and the minimap
             button. Must be an uncompressed 32-bit TGA with power-of-two
             dimensions (128x128). WoW will not load a PNG, and it fails
             silently rather than erroring, so the minimap button verifies
             the texture loaded and falls back to a stock icon if it did not.

Regenerate from a source PNG with:  .\cn.ps1 icon <path-to-png>
