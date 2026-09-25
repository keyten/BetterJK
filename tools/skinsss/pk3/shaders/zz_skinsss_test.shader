// r_skinSSS test overrides (tools/skinsss/README.md): skin masks for two characters
// whose textures mix skin with hair / beard / painted eyes. Same look as the implicit
// shaders (one lit stage), plus skinMask; the auto discovered _n / _rmo maps still
// apply. Other renderers ignore the unknown keyword.

// kyle: hair + ear + neck + cheek in one texture (excluded by default as "mixed head")
models/players/kyle/kyle_head
{
	{
		map models/players/kyle/kyle_head
		rgbGen lightingDiffuse
		skinMask models/players/kyle/kyle_head_sssmask
	}
}

// kyle: face with beard and brows
models/players/kyle/kyle_face
{
	{
		map models/players/kyle/kyle_face
		rgbGen lightingDiffuse
		skinMask models/players/kyle/kyle_face_sssmask
	}
}

// jedi_hf (customizable human female): the eyes are painted into the face textures
models/players/jedi_hf/face
{
	{
		map models/players/jedi_hf/face
		rgbGen lightingDiffuse
		skinMask models/players/jedi_hf/face_sssmask
	}
}

models/players/jedi_hf/face_a
{
	{
		map models/players/jedi_hf/face_a
		rgbGen lightingDiffuse
		skinMask models/players/jedi_hf/face_a_sssmask
	}
}

models/players/jedi_hf/face_b
{
	{
		map models/players/jedi_hf/face_b
		rgbGen lightingDiffuse
		skinMask models/players/jedi_hf/face_b_sssmask
	}
}
