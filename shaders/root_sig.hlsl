// TODO: We can remove ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT with full bindless.
// TODO: Defining this as DATA_STATIC may be incorrect.
#define ENGINE_ROOT_SIG_GRAPHICS \
	"RootFlags(ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT | CBV_SRV_UAV_HEAP_DIRECTLY_INDEXED)," \
	"RootConstants(num32BitConstants=5, b999)," \
	"CBV(b0, space = 0, flags = DATA_STATIC, visibility = SHADER_VISIBILITY_VERTEX)," \
	"StaticSampler(s100, visibility = SHADER_VISIBILITY_PIXEL," \
		"filter = FILTER_MIN_MAG_MIP_POINT," \
		"addressU = TEXTURE_ADDRESS_WRAP," \
		"addressV = TEXTURE_ADDRESS_WRAP," \
		"addressW = TEXTURE_ADDRESS_WRAP)," \
	"StaticSampler(s101, visibility = SHADER_VISIBILITY_PIXEL," \
		"filter = FILTER_MIN_MAG_POINT_MIP_LINEAR," \
		"addressU = TEXTURE_ADDRESS_WRAP," \
		"addressV = TEXTURE_ADDRESS_WRAP," \
		"addressW = TEXTURE_ADDRESS_WRAP)," \
