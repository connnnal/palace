// TODO: We can remove ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT with full bindless.
#define ROOT_SIG_GRAPHICS \
	"RootFlags(ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT | CBV_SRV_UAV_HEAP_DIRECTLY_INDEXED)," \
	"RootConstants(b0, num32BitConstants=5)," \
	"StaticSampler(s0, visibility = SHADER_VISIBILITY_PIXEL," \
		"filter = FILTER_MIN_MAG_MIP_POINT," \
		"addressU = TEXTURE_ADDRESS_WRAP," \
		"addressV = TEXTURE_ADDRESS_WRAP," \
		"addressW = TEXTURE_ADDRESS_WRAP)," \
	"StaticSampler(s1, visibility = SHADER_VISIBILITY_PIXEL," \
		"filter = FILTER_MIN_MAG_LINEAR_MIP_POINT," \
		"addressU = TEXTURE_ADDRESS_CLAMP," \
		"addressV = TEXTURE_ADDRESS_CLAMP," \
		"addressW = TEXTURE_ADDRESS_CLAMP)," \
