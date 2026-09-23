# Rend2 emissive materials

Rend2 supports an optional, stage-local emissive material channel. It is
separate from the diffuse/albedo texture and is added after reflected lighting,
AO and shadowing. The same masked emission is also written to `glowImage` for
the bloom pipeline.

Existing stages do not enable this path. The legacy `glow` keyword is unchanged:
it continues to copy the complete final stage color to `glowImage`.

## Shader keywords

```text
{
    map textures/example/panel_d
    emissiveMap textures/example/panel_e
    emissiveColor 1.0 0.25 0.05
    emissiveScale 4.0
}
```

- `emissiveMap <image>` loads an sRGB-authored color texture. Black texels are
  non-emissive, so a texture can mask small lights without making the whole
  material bloom. `$whiteimage` creates constant emission.
- `emissiveColor <r> <g> <b>` sets the linear RGB emission color. It also uses
  `$whiteimage` if no emissive map was specified.
- `emissiveScale <value>` sets a scalar linear HDR intensity.
- `emissiveScale <r> <g> <b>` is shorthand for an RGB intensity with scalar
  intensity 1. It replaces the current emissive color.

Values are clamped only at zero. Values above 1 are intentional and remain HDR
when `r_hdr` is enabled. The effective linear emission is:

```text
texture(emissiveMap).rgb * emissiveColor * emissiveScale
```

Emission uses the diffuse texture coordinates, including parallax adjustment in
the `lightall` path. On maps using the legacy display-encoded scene buffer, Rend2
decodes the existing reflected color, adds emission in linear HDR, and encodes
the combined result back for storage. Authoring values and scaling therefore
remain linear on both map types.

## Compatibility

No cvar enables the material path globally. A stage must contain one of the new
emissive keywords, so unmodified shader scripts keep a zero emissive term. With
no new keyword, `out_Color` and both the disabled and enabled legacy `glow`
outputs follow their prior expressions.

## Automatic compatibility

`r_autoEmissive` is an immediate, archived switch. Its default is `0`, preserving
the legacy output. Set it to `1` to export these existing stages as emissive
sources without adding their color to the scene a second time:

- stages carrying the legacy `glow` keyword;
- standalone unlit `blendFunc add` stages that do not use lightall, a lightmap,
  detail rendering, or a sky surface.

The structural rule intentionally rejects lit color generators, lightstyle
passes, white diffuse surfaces and bright skies. Automatic filename-suffix
discovery is not used because Jedi Academy assets do not expose a verified,
repository-wide emissive naming convention here. The switch is evaluated per
draw and does not require `vid_restart`.
