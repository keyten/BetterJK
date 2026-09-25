# Skin scatter masks for the r_skinSSS test characters (tools/skinsss/README.md).
#
# Reads the diffuse textures from the game PK3s (the last PK3 in search order wins, as in
# the game), marks skin texels with a YCbCr skin tone + luminance test, removes hand-picked
# UV regions (painted eyes), softens the edge (3x3 box, twice) and writes grayscale PNGs:
# white = scatters, black = does not (hair, beard, brows, eyes, background).
#
# usage: powershell -ExecutionPolicy Bypass -File make_masks.ps1 -BaseDir <game base> [-OutDir <dir>]
# Only these test textures are made, on purpose: no global mask authoring.

param(
	[Parameter(Mandatory = $true)][string]$BaseDir,
	[string]$OutDir = ""
)

if (-not $OutDir) { $OutDir = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "pk3" }

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.IO.Compression.FileSystem

Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @"
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public static class SkinMask
{
	static float Smooth(float a, float b, float x)
	{
		float t = Math.Max(0f, Math.Min(1f, (x - a) / (b - a)));
		return t * t * (3f - 2f * t);
	}

	// exclude: rectangles in UV (x0, y0, x1, y1), 0..1, top left origin
	public static Bitmap Make(Bitmap src, float minLuma, float[] exclude)
	{
		int w = src.Width, h = src.Height;
		Bitmap img = new Bitmap(src);
		BitmapData d = img.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
		int[] px = new int[w * h];
		Marshal.Copy(d.Scan0, px, 0, px.Length);
		img.UnlockBits(d);
		img.Dispose();

		float[] m = new float[w * h];
		for (int i = 0; i < px.Length; i++)
		{
			float r = ((px[i] >> 16) & 255), g = ((px[i] >> 8) & 255), b = (px[i] & 255);
			float y = 0.299f * r + 0.587f * g + 0.114f * b;
			float cb = 128f - 0.168736f * r - 0.331264f * g + 0.5f * b;
			float cr = 128f + 0.5f * r - 0.418688f * g - 0.081312f * b;
			// classic skin chroma box (Cb 77..127, Cr 133..173) with soft borders, widened
			// a little for the warm, desaturated JKA skins; dark texels (hair, beard,
			// brows, eye slits) are out by luminance
			float chroma = Smooth(70f, 80f, cb) * (1f - Smooth(125f, 132f, cb)) *
				Smooth(131f, 138f, cr) * (1f - Smooth(172f, 180f, cr));
			float light = Smooth(minLuma, minLuma + 25f, y);
			float warm = Smooth(4f, 14f, r - b);
			m[i] = chroma * light * warm;
		}

		for (int e = 0; e + 3 < exclude.Length; e += 4)
		{
			int x0 = (int)(exclude[e] * w), y0 = (int)(exclude[e + 1] * h);
			int x1 = (int)(exclude[e + 2] * w), y1 = (int)(exclude[e + 3] * h);
			for (int yy = Math.Max(0, y0); yy < Math.Min(h, y1); yy++)
				for (int xx = Math.Max(0, x0); xx < Math.Min(w, x1); xx++)
					m[yy * w + xx] = 0f;
		}

		for (int pass = 0; pass < 2; pass++)
		{
			float[] o = new float[w * h];
			for (int yy = 0; yy < h; yy++)
				for (int xx = 0; xx < w; xx++)
				{
					float s = 0f; int n = 0;
					for (int dy = -1; dy <= 1; dy++)
						for (int dx = -1; dx <= 1; dx++)
						{
							int x2 = xx + dx, y2 = yy + dy;
							if (x2 < 0 || y2 < 0 || x2 >= w || y2 >= h) continue;
							s += m[y2 * w + x2]; n++;
						}
					o[yy * w + xx] = s / n;
				}
			m = o;
		}

		Bitmap dst = new Bitmap(w, h, PixelFormat.Format32bppArgb);
		BitmapData od = dst.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
		int[] op = new int[w * h];
		for (int i = 0; i < op.Length; i++)
		{
			int v = (int)Math.Round(Math.Max(0f, Math.Min(1f, m[i])) * 255f);
			op[i] = unchecked((int)0xFF000000) | (v << 16) | (v << 8) | v;
		}
		Marshal.Copy(op, 0, od.Scan0, op.Length);
		dst.UnlockBits(od);
		return dst;
	}
}
"@

function Read-GameImage([string]$path) {
	# last PK3 in search order (alphabetical) wins
	$found = $null
	foreach ($pk3 in (Get-ChildItem -Path $BaseDir -Filter *.pk3 | Sort-Object Name)) {
		$zip = [System.IO.Compression.ZipFile]::OpenRead($pk3.FullName)
		try {
			foreach ($ext in ".jpg", ".png", ".tga") {
				$entry = $zip.Entries | Where-Object { $_.FullName -ieq ($path + $ext) } | Select-Object -First 1
				if ($entry) {
					$ms = New-Object System.IO.MemoryStream
					$s = $entry.Open(); $s.CopyTo($ms); $s.Close()
					$found = @{ Stream = $ms; Pk3 = $pk3.Name; Ext = $ext }
					break
				}
			}
		} finally { $zip.Dispose() }
	}
	if (-not $found) { throw "not found: $path" }
	if ($found.Ext -eq ".tga") { throw "TGA source not supported by System.Drawing: $path" }
	$found.Stream.Position = 0
	Write-Host "$path$($found.Ext) from $($found.Pk3)"
	return [System.Drawing.Bitmap]::FromStream($found.Stream)
}

# texture, minimum luma (0..255), excluded UV rectangles
$jobs = @(
	# kyle: head = hair + ear + neck + cheek strip, face = face with beard / brows
	@{ Tex = "models/players/kyle/kyle_head"; Luma = 42; Exclude = @() },
	@{ Tex = "models/players/kyle/kyle_face"; Luma = 42; Exclude = @() },
	# jedi_hf: eyes painted in the top strip of the face textures
	@{ Tex = "models/players/jedi_hf/face";   Luma = 45; Exclude = @(0.0, 0.0, 1.0, 0.31) },
	@{ Tex = "models/players/jedi_hf/face_a"; Luma = 45; Exclude = @(0.0, 0.0, 1.0, 0.31) },
	@{ Tex = "models/players/jedi_hf/face_b"; Luma = 45; Exclude = @(0.0, 0.0, 1.0, 0.31) }
)

foreach ($job in $jobs) {
	$src = Read-GameImage $job.Tex
	$mask = [SkinMask]::Make($src, [float]$job.Luma, [float[]]$job.Exclude)
	$out = Join-Path $OutDir ($job.Tex + "_sssmask.png")
	New-Item -ItemType Directory -Force (Split-Path $out) | Out-Null
	$mask.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
	Write-Host "  -> $out ($($mask.Width)x$($mask.Height))"
	$mask.Dispose(); $src.Dispose()
}
