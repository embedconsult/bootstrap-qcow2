#include <vector>
#include <string>
#include <cstdlib>
#include "llvm/Support/InitLLVM.h"
#include "llvm/Support/Signals.h"
#include "llvm/Support/TargetSelect.h"
#include "llvm/Support/raw_ostream.h"

// Provided by libclang-cpp
int clang_main(int, const char**);

static void inproc_init_targets_once() {
	static bool inited = false;
	if (inited) return;
	LLVMInitializeX86TargetInfo();
	LLVMInitializeX86Target();
	LLVMInitializeX86AsmParser();
	LLVMInitializeX86AsmPrinter();
	LLVMInitializeAArch64TargetInfo();
	LLVMInitializeAArch64Target();
	LLVMInitializeAArch64AsmParser();
	LLVMInitializeAArch64AsmPrinter();
	inited = true;
}

static int run_clang(int argc, const char* argv[]) {
	inproc_init_targets_once();
	int Argc = argc;
	const char **Argv = argv;
	llvm::InitLLVM X(Argc, Argv);
	llvm::sys::PrintStackTraceOnErrorSignal(argv && argv[0] ? argv[0] : "inproc_clang");
	setenv("CLANG_SPAWN_CC1", "0", 1);
	return clang_main(argc, argv);
}

extern "C" int inproc_clang(int argc, const char* argv[]) {
	return run_clang(argc, argv);
}

extern "C" int inproc_link_via_clang(int argc, const char* argv[]) {
	std::vector<std::string> owned;
	owned.reserve((size_t)argc + 4);
	if (argc > 0) owned.emplace_back("clang");
	else owned.emplace_back("clang");
	bool have_fuse_ld = false;
	for (int i = 1; i < argc; ++i) {
		std::string s = argv[i] ? argv[i] : "";
		if (s == "-fuse-ld=lld") have_fuse_ld = true;
		owned.emplace_back(std::move(s));
	}
	if (!have_fuse_ld) owned.emplace_back("-fuse-ld=lld");
	std::vector<const char*> cargs;
	cargs.reserve(owned.size());
	for (auto &s : owned) cargs.push_back(s.c_str());
	return run_clang((int)cargs.size(), cargs.data());
}
