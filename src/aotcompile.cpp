// This file is a part of Julia. License is MIT: https://julialang.org/license

#include "llvm-version.h"
#include "platform.h"

// target support
#include <llvm/TargetParser/Triple.h>
#include "llvm/Support/CodeGen.h"
#include <llvm/ADT/Statistic.h>
#include <llvm/Analysis/TargetLibraryInfo.h>
#include <llvm/Analysis/TargetTransformInfo.h>
#include <llvm/IR/DataLayout.h>
#include <llvm/MC/TargetRegistry.h>
#include <llvm/Target/TargetMachine.h>

// analysis passes
#include <llvm/Analysis/Passes.h>
#include <llvm/IR/DerivedTypes.h>
#include <llvm/IR/IRBuilder.h>
#include <llvm/IR/AttributeMask.h>
#include <llvm/IR/PassManager.h>
#include <llvm/IR/Verifier.h>
#include <llvm/Transforms/Utils/ModuleUtils.h>
#include <llvm/Passes/PassBuilder.h>
#  include <llvm/Plugins/PassPlugin.h>
#if defined(USE_POLLY)
#include <polly/RegisterPasses.h>
#include <polly/LinkAllPasses.h>
#include <polly/CodeGen/CodegenCleanup.h>
#if defined(USE_POLLY_ACC)
#include <polly/Support/LinkGPURuntime.h>
#endif
#endif

// for outputting code
#include <llvm/Bitcode/BitcodeWriter.h>
#include <llvm/Bitcode/BitcodeWriterPass.h>
#include <llvm/Bitcode/BitcodeReader.h>
#include "llvm/Object/ArchiveWriter.h"
#include <llvm/IR/IRPrintingPasses.h>

#include <llvm/IR/LegacyPassManagers.h>
#include <llvm/Transforms/Utils/Cloning.h>
#include <llvm/Support/FormatAdapters.h>
#include <llvm/Linker/Linker.h>
#include <llvm/Support/TimeProfiler.h>

using namespace llvm;

#include <atomic>
#include <mutex>

#include "jitlayers.h"
#include "serialize.h"
#include "julia_assert.h"
#include "processor.h"

#ifdef _OS_WINDOWS_
#include <windows.h>
#else
#include <semaphore.h>
#include <fcntl.h>
#endif

#ifdef USE_TRACY
#include "tracy/TracyC.h"
#endif

#define DEBUG_TYPE "julia_aotcompile"

// Client for the precompile jobserver (see JuliaLang/julia#58591). The
// orchestrator creates a named semaphore whose tokens form a single CPU-thread
// budget shared across all parallel workers and holds one baseline token per
// CPU-active worker; each worker opens it by name (via JULIA_PRECOMPILE_JOBSERVER)
// to acquire extra tokens for its imaging phase. The worker's main thread sleeps
// while its imaging threads run, so that baseline token doubles as the imaging
// phase's first codegen thread. The pool is elastic (see add_output), letting a
// lone worker expand to all cores while concurrent workers share the budget.
namespace {
struct JobserverClient {
#ifdef _OS_WINDOWS_
    HANDLE sem = NULL;
#else
    sem_t *sem = SEM_FAILED;
#endif
    bool open() {
        const char *name = getenv("JULIA_PRECOMPILE_JOBSERVER");
        if (!name || !*name)
            return false;
#ifdef _OS_WINDOWS_
        sem = OpenSemaphoreA(SEMAPHORE_MODIFY_STATE | SYNCHRONIZE, FALSE, name);
        return sem != NULL;
#else
        sem = sem_open(name, 0);
        return sem != SEM_FAILED;
#endif
    }
    bool active() const {
#ifdef _OS_WINDOWS_
        return sem != NULL;
#else
        return sem != SEM_FAILED;
#endif
    }
    // Acquire up to `want` tokens without blocking; returns the number acquired.
    unsigned acquire(unsigned want) {
        if (!active())
            return 0;
        unsigned got = 0;
        for (; got < want; got++) {
#ifdef _OS_WINDOWS_
            if (WaitForSingleObject(sem, 0) != WAIT_OBJECT_0)
                break;
#else
            if (sem_trywait(sem) != 0)
                break;
#endif
        }
        return got;
    }
    void release(unsigned n) {
        if (!active())
            return;
        for (unsigned i = 0; i < n; i++) {
#ifdef _OS_WINDOWS_
            ReleaseSemaphore(sem, 1, NULL);
#else
            sem_post(sem);
#endif
        }
    }
    void close() {
        if (!active())
            return;
#ifdef _OS_WINDOWS_
        CloseHandle(sem);
        sem = NULL;
#else
        sem_close(sem);
        sem = SEM_FAILED;
#endif
    }
};
} // namespace

STATISTIC(CreateNativeCalls, "Number of jl_create_native calls made");
STATISTIC(CreateNativeMethods, "Number of methods compiled for jl_create_native");
STATISTIC(CreateNativeMax, "Max number of methods compiled at once for jl_create_native");
STATISTIC(CreateNativeGlobals, "Number of globals compiled for jl_create_native");

static void addComdat(GlobalValue *G, Triple &T)
{
    if (T.isOSBinFormatCOFF() && !G->isDeclaration()) {
        // add __declspec(dllexport) to everything marked for export
        assert(G->hasExternalLinkage() && "Cannot set DLLExport on non-external linkage!");
        G->setDLLStorageClass(GlobalValue::DLLExportStorageClass);
    }
}

typedef struct {
    orc::ThreadSafeModule TSM;
    orc::ThreadSafeModule *TSM_ref;
    std::unique_ptr<jl_codegen_output_t> out;
    SmallVector<GlobalValue*, 0> jl_sysimg_fvars;
    SmallVector<GlobalValue*, 0> jl_sysimg_gvars;
    std::map<jl_code_instance_t*, std::tuple<uint32_t, uint32_t>> jl_fvar_map;
    SmallVector<void*, 0> jl_value_to_llvm;
    SmallVector<jl_code_instance_t*, 0> jl_external_to_llvm;
    // ordered list of CodeInstances emitted for this image, in the order they
    // were presented in `codeinfos`; consumed by staticdata.c to rewrite each
    // MethodInstance's `cache` field into a `next`-linked list
    SmallVector<jl_code_instance_t*, 0> jl_ci_order;
    // coverage counters emitted into the image: (file, line, flags, symbol),
    // serialized as the `jl_image_coverage` table
    SmallVector<std::tuple<std::string, int32_t, uint32_t, std::string>, 0> jl_coverage_entries;
    // The parts of a store that the image takes (`jl_set_code_parts`): the
    // ranges of their slots and of their functions in the tables, and their
    // objects as (member name, bytes) for the archive.
    size_t part_gvars_begin = 0, part_gvars_end = 0;
    size_t part_fvars_begin = 0, part_fvars_end = 0;
    std::vector<std::pair<std::string, std::string>> part_objects;
} jl_native_code_desc_t;

extern "C" JL_DLLEXPORT_CODEGEN
void jl_get_function_id_impl(void *native_code, jl_code_instance_t *codeinst,
        int32_t *func_idx, int32_t *specfunc_idx)
{
    jl_native_code_desc_t *data = (jl_native_code_desc_t*)native_code;
    if (data) {
        // get the function index in the fvar lookup table
        auto it = data->jl_fvar_map.find(codeinst);
        if (it != data->jl_fvar_map.end()) {
            std::tie(*func_idx, *specfunc_idx) = it->second;
        }
    }
}

extern "C" JL_DLLEXPORT_CODEGEN void
jl_get_llvm_cis_impl(void *native_code, size_t *num_elements, jl_code_instance_t **data)
{
    jl_native_code_desc_t *desc = (jl_native_code_desc_t *)native_code;
    auto &map = desc->jl_fvar_map;

    if (data == NULL) {
        *num_elements = map.size();
        return;
    }

    assert(*num_elements == map.size());
    size_t i = 0;
    for (auto &ci : map) {
        data[i++] = ci.first;
    }
}

// get the ordered list of CodeInstances that were emitted for this image, in
// the order they appeared in `codeinfos`. staticdata.c uses this to rewrite the
// `cache` field of each MethodInstance into a `next`-linked list.
extern "C" JL_DLLEXPORT_CODEGEN void
jl_get_llvm_mi_cache_order_impl(void *native_code, size_t *num_elements, jl_code_instance_t **data)
{
    jl_native_code_desc_t *desc = (jl_native_code_desc_t *)native_code;
    auto &order = desc->jl_ci_order;

    if (data == NULL) {
        *num_elements = order.size();
        return;
    }

    assert(*num_elements == order.size());
    memcpy(data, order.data(), *num_elements * sizeof(jl_code_instance_t *));
}

// get the list of global variables managed by the compiler
extern "C" JL_DLLEXPORT_CODEGEN void jl_get_llvm_gvs_impl(void *native_code,
                                                          size_t *num_elements, void **data)
{
    jl_native_code_desc_t *desc = (jl_native_code_desc_t *)native_code;
    auto &gvars = desc->jl_sysimg_gvars;

    if (data == NULL) {
        *num_elements = gvars.size();
        return;
    }

    assert(*num_elements == gvars.size());
    memcpy(data, gvars.data(), *num_elements * sizeof(void *));
}

// get the initializer values (jl_value_t or jl_binding_t ptr) of managed global variables
extern "C" JL_DLLEXPORT_CODEGEN void jl_get_llvm_gv_inits_impl(void *native_code,
                                                               size_t *num_elements,
                                                               void **data)
{
    jl_native_code_desc_t *desc = (jl_native_code_desc_t *)native_code;
    auto &inits = desc->jl_value_to_llvm;

    if (data == NULL) {
        *num_elements = inits.size();
        return;
    }

    assert(*num_elements == inits.size());
    memcpy(data, inits.data(), *num_elements * sizeof(void *));
}

extern "C" JL_DLLEXPORT_CODEGEN void jl_get_llvm_external_fns_impl(void *native_code,
                                                                   size_t *num_elements,
                                                                   jl_code_instance_t *data)
{
    jl_native_code_desc_t *desc = (jl_native_code_desc_t *)native_code;
    auto &external_map = desc->jl_external_to_llvm;

    if (data == NULL) {
        *num_elements = external_map.size();
        return;
    }

    assert(*num_elements == external_map.size());
    memcpy((void *)data, (const void *)external_map.data(),
           *num_elements * sizeof(jl_code_instance_t *));
}

extern "C" JL_DLLEXPORT_CODEGEN
LLVMOrcThreadSafeModuleRef jl_get_llvm_module_impl(void *native_code)
{
    jl_native_code_desc_t *data = (jl_native_code_desc_t*)native_code;
    if (data)
        return wrap(data->TSM_ref);
    else
        return NULL;
}

// frees native code that is not dumped, e.g. after taking its module with
// `jl_get_llvm_module`. this drops the native code's reference to the LLVM context.
extern "C" JL_DLLEXPORT_CODEGEN
void jl_free_native_impl(void *native_code)
{
    delete (jl_native_code_desc_t*)native_code;
}

extern "C" JL_DLLEXPORT_CODEGEN
GlobalValue* jl_get_llvm_function_impl(void *native_code, uint32_t idx)
{
    jl_native_code_desc_t *data = (jl_native_code_desc_t*)native_code;
    if (data)
        return data->jl_sysimg_fvars[idx];
    else
        return NULL;
}



template<typename T>
static inline SmallVector<T*, 0> consume_gv(Module &M, const char *name, bool allow_bad_fvars)
{
    // Get information about sysimg export functions from the two global variables.
    // Strip them from the Module so that it's easier to handle the uses.
    GlobalVariable *gv = M.getGlobalVariable(name);
    assert(gv && gv->hasInitializer());
    ArrayType *Ty = cast<ArrayType>(gv->getInitializer()->getType());
    unsigned nele = Ty->getArrayNumElements();
    SmallVector<T*, 0> res(nele);
    ConstantArray *ary = nullptr;
    if (gv->getInitializer()->isNullValue()) {
        for (unsigned i = 0; i < nele; ++i)
            res[i] = cast<T>(Constant::getNullValue(Ty->getArrayElementType()));
    }
    else {
        ary = cast<ConstantArray>(gv->getInitializer());
        unsigned i = 0;
        while (i < nele) {
            llvm::Value *val = ary->getOperand(i)->stripPointerCasts();
            if (allow_bad_fvars && (!isa<T>(val) || (isa<Function>(val) && cast<Function>(val)->isDeclaration()))) {
                // Shouldn't happen in regular use, but can happen in bugpoint.
                nele--;
                continue;
            }
            res[i++] = cast<T>(val);
        }
        res.resize(nele);
    }
    assert(gv->use_empty());
    gv->eraseFromParent();
    if (ary && ary->use_empty())
        ary->destroyConstant();
    return res;
}

static Constant *get_ptrdiff32(Type *T_size, Constant *ptr, Constant *base)
{
    if (ptr->getType()->isPointerTy())
        ptr = ConstantExpr::getPtrToInt(ptr, T_size);
    auto ptrdiff = ConstantExpr::getSub(ptr, base);
    return T_size->getPrimitiveSizeInBits() > 32 ? ConstantExpr::getTrunc(ptrdiff, Type::getInt32Ty(ptr->getContext())) : ptrdiff;
}

static Constant *emit_offset_table(Module &M, Type *T_size, ArrayRef<Constant*> vars,
                                   StringRef name, StringRef suffix)
{
    auto T_int32 = Type::getInt32Ty(M.getContext());
    uint32_t nvars = vars.size();
    ArrayType *vars_type = ArrayType::get(T_int32, nvars + 1);
    auto gv = new GlobalVariable(M, vars_type, true,
                                 GlobalVariable::ExternalLinkage,
                                 nullptr,
                                 name + "_offsets" + suffix);
    auto vbase = ConstantExpr::getPtrToInt(gv, T_size);
    SmallVector<Constant*, 0> offsets(nvars + 1);
    offsets[0] = ConstantInt::get(T_int32, nvars);
    for (uint32_t i = 0; i < nvars; i++)
        offsets[i + 1] = get_ptrdiff32(T_size, vars[i], vbase);
    gv->setInitializer(ConstantArray::get(vars_type, offsets));
    gv->setVisibility(GlobalValue::HiddenVisibility);
    gv->setDSOLocal(true);
    return vbase;
}

static void emit_table(Module &mod, ArrayRef<GlobalValue*> vars,
                       StringRef name, Type *T_psize)
{
    // Emit a global variable with all the variable addresses.
    size_t nvars = vars.size();
    SmallVector<Constant*, 0> addrs(nvars);
    for (size_t i = 0; i < nvars; i++) {
        Constant *var = vars[i];
        addrs[i] = ConstantExpr::getBitCast(var, T_psize);
    }
    ArrayType *vars_type = ArrayType::get(T_psize, nvars);
    auto GV = new GlobalVariable(mod, vars_type, true,
                       GlobalVariable::ExternalLinkage,
                       ConstantArray::get(vars_type, addrs),
                       name);
    GV->setVisibility(GlobalValue::HiddenVisibility);
    GV->setDSOLocal(true);
}

static bool is_safe_char(unsigned char c)
{
    return ('0' <= c && c <= '9') ||
           ('A' <= c && c <= 'Z') ||
           ('a' <= c && c <= 'z') ||
           (c == '_' || c == '$') ||
           (c >= 128 && c < 255);
}

static const char hexchars[16] = {
    '0', '1', '2', '3', '4', '5', '6', '7',
    '8', '9', 'A', 'B', 'C', 'D', 'E', 'F' };

static const char *const common_names[256] = {
//  0, 1, 2, 3, 4, 5, 6, 7, 8, 9, a, b, c, d, e, f
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 0x00
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 0x10
    "SP", "NOT", "DQT", "YY", 0, "REM", "AND", "SQT", // 0x20
      "LPR", "RPR", "MUL", "SUM", 0, "SUB", "DOT", "DIV", // 0x28
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, "COL", 0, "LT", "EQ", "GT", "QQ", // 0x30
    "AT", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 0x40
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, "LBR", "RDV", "RBR", "POW", 0, // 0x50
    "TIC", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 0x60
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, "LCR", "OR", "RCR", "TLD", "DEL", // 0x70
    0 }; // remainder is filled with zeros, though are also all safe characters

// reversibly removes special characters from the name of GlobalObjects,
// which might cause them to be treated special by LLVM or the system linker
// the only non-identifier characters we allow to appear are '.' and '$',
// and all of UTF-8 above code-point 128 (except 255)
// most are given "friendly" abbreviations
// the remaining few will print as hex
// e.g. mangles "llvm.a≠a$a!a##" as "llvmDOT.a≠a$aNOT.aYY.YY."
static void makeSafeName(GlobalObject &G)
{
    StringRef Name = G.getName();
    SmallVector<char, 32> SafeName;
    for (unsigned char c : Name.bytes()) {
        if (is_safe_char(c)) {
            SafeName.push_back(c);
        }
        else {
            if (common_names[c]) {
                SafeName.push_back(common_names[c][0]);
                SafeName.push_back(common_names[c][1]);
                if (common_names[c][2])
                    SafeName.push_back(common_names[c][2]);
            }
            else {
                SafeName.push_back(hexchars[(c >> 4) & 0xF]);
                SafeName.push_back(hexchars[c & 0xF]);
            }
            SafeName.push_back('.');
        }
    }
    if (SafeName.size() != Name.size())
        G.setName(StringRef(SafeName.data(), SafeName.size()));
}

namespace { // file-local namespace
class JL_GC_TRACKED_TYPE egal_set {
public:
    jl_genericmemory_t *list = (jl_genericmemory_t*)jl_an_empty_memory_any;
    jl_genericmemory_t *keyset = (jl_genericmemory_t*)jl_an_empty_memory_any;
    size_t max = 0;
    egal_set(egal_set&) = delete;
    egal_set(egal_set&&) = delete;
    egal_set() = default;
    void insert(jl_value_t *val) JL_CANSAFEPOINT
    {
        // list/keyset are GC-rooted by the caller via JL_GC_PUSH
        JL_GC_PROMISE_ROOTED(val);
        JL_GC_PROMISE_ROOTED(list);
        JL_GC_PROMISE_ROOTED(keyset);
        jl_value_t *rval = jl_idset_get(list, keyset, val);
        if (rval == NULL) {
            ssize_t idx;
            list = jl_idset_put_key(list, val, &max, &idx);
            JL_GC_PROMISE_ROOTED(list);
            keyset = jl_idset_put_idx(list, keyset, idx);
        }
    }
    jl_value_t *get(jl_value_t *val)
    {
        return jl_idset_get(list, keyset, val);
    }
};
}
using ::egal_set;
typedef DenseMap<jl_code_instance_t*, jl_llvm_functions_t> jl_compiled_functions_t;

static void record_method_roots(egal_set &method_roots, jl_method_instance_t *mi) JL_CANSAFEPOINT
{
    jl_method_t *m = mi->def.method;
    if (!jl_is_method(m))
        return;
    // the method might have a root for this already; use it if so
    JL_LOCK(&m->writelock);
    if (m->roots) {
        size_t j, len = jl_array_dim0(m->roots);
        for (j = 0; j < len; j++) {
            jl_value_t *v = jl_array_ptr_ref(m->roots, j);
            if (jl_is_globally_rooted(v))
                continue;
            method_roots.insert(v);
        }
    }
    JL_UNLOCK(&m->writelock);
}

static void aot_optimize_roots(jl_codegen_output_t &out, egal_set &method_roots) JL_CANSAFEPOINT
{
    for (size_t i = 0; i < jl_array_dim0(out.temporary_roots); i++) {
        jl_value_t *val = jl_array_ptr_ref(out.temporary_roots, i);
        auto ref = out.global_targets.find((void*)val);
        if (ref == out.global_targets.end())
            continue;
        auto get_global_root = [val, &method_roots]() JL_CANSAFEPOINT {
            if (jl_is_globally_rooted(val))
                return val;
            // `--trim` / `--strip-ir` drop all method roots in the serializer
            // under the assumption that they root only objects for compressed
            // IR so any roots for codegen must be stored separately
            if (!(jl_options.trim || jl_options.strip_ir)) {
                jl_value_t *mval = method_roots.get(val);
                if (mval)
                    return mval;
            }
            return jl_as_global_root(val, 1);
        };
        jl_value_t *mval = get_global_root();
        if (mval != val) {
            GlobalVariable *GV = ref->second;
            out.global_targets.erase(ref);
            auto mref = out.global_targets.find((void*)mval);
            if (mref == out.global_targets.end()) {
                out.global_targets[(void *)mval] = GV;
            } else {
                GV->replaceAllUsesWith(mref->second);
                GV->eraseFromParent();
            }
        }
    }
}

static Function *aot_abi_converter(jl_codegen_output_t &out, jl_abi_t from_abi, jl_code_instance_t *codeinst, Function *func, Function *specfunc, bool target_specsig) JL_CANSAFEPOINT
{
    std::string gf_thunk_name;
    if (specfunc)
        gf_thunk_name = emit_abi_converter(out, from_abi, codeinst, specfunc, target_specsig);
    else
        gf_thunk_name = emit_abi_dispatcher(out, from_abi, codeinst, func);
    auto F = out.get_module().getFunction(gf_thunk_name);
    assert(F);
    return F;
}

static void generate_cfunc_thunks(jl_codegen_output_t &out) JL_CANSAFEPOINT
{
    DenseMap<jl_method_instance_t*, jl_code_instance_t*> compiled_mi;
    for (auto &[ci, _] : out.ci_funcs) {
        jl_method_instance_t *mi = jl_get_ci_mi(ci);
        if ((ci->owner == jl_nothing || ci->owner == (jl_value_t*)jl_trim_sym) &&
            jl_atomic_load_relaxed(&ci->max_world) == ~(size_t)0 && ci->def == (jl_value_t*)mi)
            compiled_mi[mi] = ci;
    }
    size_t latestworld = jl_atomic_load_acquire(&jl_world_counter);
    for (cfunc_decl_t &cfunc : out.cfuncs) {
        jl_value_t *sigt = cfunc.abi.sigt;
        JL_GC_PROMISE_ROOTED(sigt);
        jl_value_t *declrt = cfunc.abi.rt;
        JL_GC_PROMISE_ROOTED(declrt);
        Function *unspec = aot_abi_converter(out, cfunc.abi, nullptr, nullptr, nullptr, false);
        jl_code_instance_t *codeinst = nullptr;
        auto assign_fptr = [&out, &cfunc, &codeinst, &unspec](Function *f) JL_CANSAFEPOINT {
            ConstantArray *init = cast<ConstantArray>(cfunc.cfuncdata->getInitializer());
            SmallVector<Constant*,8> initvals;
            for (unsigned i = 0; i < init->getNumOperands(); ++i)
                initvals.push_back(init->getOperand(i));
            assert(initvals.size() == 8);
            assert(initvals[0]->isNullValue());
            assert(initvals[2]->isNullValue());
            if (codeinst) {
                Constant *llvmcodeinst = literal_pointer_val_slot(out, (jl_value_t*)codeinst);
                initvals[2] = llvmcodeinst; // plast_codeinst
            }
            assert(initvals[4]->isNullValue());
            initvals[4] = unspec;
            initvals[0] = f;
            cfunc.cfuncdata->setInitializer(ConstantArray::get(init->getType(), initvals));
        };
        jl_method_instance_t *mi = (jl_method_instance_t*)jl_get_specialization1((jl_tupletype_t*)sigt, latestworld);
        Function *func = nullptr;
        if ((jl_value_t*)mi != jl_nothing) {
            auto it = compiled_mi.find(mi);
            if (it != compiled_mi.end()) {
                codeinst = it->second;
                JL_GC_PROMISE_ROOTED(codeinst);
                const auto &decls = out.ci_funcs.find(codeinst)->second;
                jl_value_t *astrt = codeinst->rettype;
                if (astrt != (jl_value_t*)jl_bottom_type &&
                    jl_type_intersection(astrt, declrt) == jl_bottom_type) {
                    // Do not warn if the function never returns since it is
                    // occasionally required by the C API (typically error callbacks)
                    // even though we're likely to encounter memory errors in that case
                    jl_printf(JL_STDERR, "WARNING: cfunction: return type of %s does not match\n", name_from_method_instance(mi));
                }
                if (decls.invoke_api == JL_INVOKE_CONST) {
                    std::string gf_thunk_name = emit_abi_constreturn(out, cfunc.abi, codeinst->rettype_const);
                    auto F = out.get_module().getFunction(gf_thunk_name);
                    assert(F);
                    assign_fptr(F);
                    continue;
                }
                else if (decls.invoke_api == JL_INVOKE_ARGS) {
                    assert(decls.specptr);
                    if (!cfunc.abi.specsig && jl_subtype(astrt, declrt)) {
                        assign_fptr(decls.specptr);
                        continue;
                    }
                    assign_fptr(aot_abi_converter(out, cfunc.abi, codeinst, nullptr, decls.specptr, false));
                    continue;
                }
                else if (decls.invoke_api == JL_INVOKE_SPARAM) {
                    func = nullptr; // use jl_invoke instead for these, since we don't declare these prototypes
                }
                else {
                    assert(decls.specptr);
                    if (jl_egal(mi->specTypes, sigt) && jl_egal(declrt, astrt)) {
                        assign_fptr(decls.specptr);
                        continue;
                    }
                    assign_fptr(aot_abi_converter(out, cfunc.abi, codeinst, func, decls.specptr, true));
                    continue;
                }
            }
        }
        Function *f = codeinst ? aot_abi_converter(out, cfunc.abi, codeinst, func, nullptr, false) : unspec;
        assign_fptr(f);
    }
}

// Coverage counters are the module-local globals `newCoverageCounter` in
// codegen.cpp creates; they are identified by their name prefix. Keep both in
// sync if counters ever get a metadata tag or a dedicated section instead.
static bool isCoverageCounter(const GlobalValue &G)
{
    return G.getName().starts_with("jl_covctr");
}

static bool canPartition(const Function &F)
{
    return !F.hasFnAttribute(Attribute::AlwaysInline) &&
           !F.hasFnAttribute(Attribute::InlineHint);
}

// this builds the object file portion of the sysimage files for fast startup
static jl_native_code_desc_t *emit_native_code(jl_array_t *codeinfos, jl_array_t *ci_order, LLVMOrcThreadSafeModuleRef llvmmod,
                                          const jl_cgparams_t *cgparams, int external_linkage,
                                          const DenseMap<jl_code_instance_t *, std::string> *part_names,
                                          jl_value_t *code_parts = nullptr) JL_CANSAFEPOINT;

// The parts of a store for the next image that this process writes, which
// `jl_set_code_parts` sets and `jl_create_native` takes. The caller keeps the
// table alive until the image is written.
static jl_value_t *jl_code_parts = nullptr;

// Give the next image that this process writes the machine code of functions
// from parts (`jl_emit_object` with names). `parts` is
// `svec(functions, objects, aliases)`:
// - `functions`: a `svec(mi, invoke_api, invoke, specptr)` for each method
//   instance whose code a part holds, with the names of its symbols; the image
//   does not compile its code instance, and its entries in the table of
//   functions name the symbols of the part;
// - `objects`: a `svec(bytes, prefix, slots)` for each part, with the Julia
//   object of each of its slots, which the image fills as its own slots;
// - `aliases`: a `svec(mi, invoke_api, name, ci)` for each name that a part
//   calls and that the image defines: the code instance that the image
//   compiles for `mi` when `ci` is `nothing`, else `ci`, the code of another
//   image, which the image calls as it calls other images.
// `parts` can also be a function of the list of code that the image takes (as
// the bridge of the compiler answers it), which `jl_create_native` calls in
// the latest world and which answers such a table or `nothing`; it can then
// check each part against the code instance that the image takes.
// `nothing` clears the table.
extern "C" JL_DLLEXPORT_CODEGEN
void jl_set_code_parts_impl(jl_value_t *parts)
{
    jl_code_parts = parts == jl_nothing ? nullptr : parts;
}

// `external_linkage` create linkages between pkgimages.
extern "C" JL_DLLEXPORT_CODEGEN
void *jl_create_native_impl(LLVMOrcThreadSafeModuleRef llvmmod, int trim, int external_linkage, size_t world,
                           jl_array_t *mod_array, jl_array_t *worklist, int all, jl_array_t *module_init_order, jl_array_t *ext_foreign_cis)
{
    JL_TIMING(INFERENCE, INFERENCE);
    auto ct = jl_current_task;
    if (!jl_compile_and_emit_func) {
        jl_error("inference not available for generating compiled output");
    }
    bool timed = (ct->reentrant_timing & 1) == 0;
    if (timed)
        ct->reentrant_timing |= 1;
    uint64_t compiler_start_time = 0;
    uint8_t measure_compile_time_enabled = jl_atomic_load_relaxed(&jl_measure_compile_time_enabled);
    if (measure_compile_time_enabled)
        compiler_start_time = jl_hrtime();

    jl_value_t **fargs;
    JL_GC_PUSHARGS(fargs, 9);
#ifdef _P64
    jl_value_t *jl_array_ulong_type = jl_array_uint64_type;
#else
    jl_value_t *jl_array_ulong_type = jl_array_uint32_type;
#endif
    jl_array_t *worlds = jl_alloc_array_1d(jl_array_ulong_type, 2);
    fargs[0] = jl_compile_and_emit_func;
    fargs[1] = (jl_value_t*)worlds;
    jl_array_data(worlds, size_t)[0] = jl_typeinf_world;
    int compiler_world = 1;
    if (trim || jl_array_data(worlds, size_t)[0] == 0 || jl_array_data(worlds, size_t)[0] == world || external_linkage)
        compiler_world = 0;
    jl_array_data(worlds, size_t)[compiler_world] = world; // might overwrite previous
    worlds->dimsize[0] = 1 + compiler_world;
    fargs[2] = jl_box_uint8(trim);
    fargs[3] = jl_box_bool(external_linkage);
    fargs[4] = worklist ? (jl_value_t*)worklist : jl_nothing; // worklist (or nothing)
    fargs[5] = mod_array ? (jl_value_t*)mod_array : jl_nothing; // mod_array (or nothing)
    fargs[6] = jl_box_bool(all);
    fargs[7] = (jl_value_t*)module_init_order; // module_init_order
    fargs[8] = ext_foreign_cis ? (jl_value_t*)ext_foreign_cis : jl_nothing; // ext_foreign_cis (or nothing)
    size_t last_age = ct->world_age;
    ct->world_age = jl_typeinf_world;
    fargs[0] = jl_apply(fargs, 9);
    fargs[1] = fargs[2] = fargs[3] = fargs[4] = fargs[5] = fargs[6] = fargs[7] = fargs[8] = NULL;
    ct->world_age = last_age;
    // the bridge returns svec(codeinfos, ci_order): the interleaved
    // CodeInstance/CodeInfo work list to emit, and the ordered CodeInstances to
    // store in the method caches of the output image
    jl_value_t *result = fargs[0];
    assert(jl_is_svec(result) && jl_svec_len(result) == 2);
    jl_value_t *codeinfos = jl_svecref(result, 0);
    jl_value_t *ci_order = jl_svecref(result, 1);
    JL_TYPECHK(jl_create_native, array_any, codeinfos);
    JL_TYPECHK(jl_create_native, array_any, ci_order);
    // A code instance whose code a part of the store holds does not compile.
    jl_value_t *code_parts = jl_code_parts;
    jl_code_parts = nullptr;
    if (code_parts && !jl_is_svec(code_parts)) {
        size_t world_before = ct->world_age;
        ct->world_age = jl_atomic_load_acquire(&jl_world_counter);
        jl_value_t *table = jl_call1(code_parts, codeinfos);
        ct->world_age = world_before;
        if (table == NULL) {
            jl_safe_printf("jl_create_native: the function of the parts failed: ");
            jl_static_show(JL_STDERR, jl_current_exception(ct));
            jl_safe_printf("\n");
        }
        code_parts = table && jl_is_svec(table) ? table : nullptr;
        fargs[5] = code_parts;
    }
    DenseMap<jl_code_instance_t *, std::string> part_names;
    if (code_parts) {
        // The table names method instances; the code instances are those that
        // this image takes.
        DenseMap<jl_method_instance_t *, jl_svec_t *> by_mi;
        jl_array_t *functions = (jl_array_t *)jl_svecref(code_parts, 0);
        for (size_t k = 0; k < jl_array_nrows(functions); k++) {
            jl_svec_t *entry = (jl_svec_t *)jl_array_ptr_ref(functions, k);
            by_mi[(jl_method_instance_t *)jl_svecref(entry, 0)] = entry;
        }
        jl_array_t *all = (jl_array_t *)codeinfos;
        jl_array_t *kept = jl_alloc_vec_any(0);
        fargs[1] = (jl_value_t *)kept;
        jl_array_t *taken = jl_alloc_vec_any(0);
        fargs[2] = (jl_value_t *)taken;
        DenseMap<jl_method_instance_t *, jl_code_instance_t *> compiled;
        // Each item is a code instance followed by its source, or one
        // `svec(rettype, sig)` of a C-callable alias.
        for (size_t i = 0; i < jl_array_nrows(all); i++) {
            jl_value_t *item = jl_array_ptr_ref(all, i);
            if (!jl_is_code_instance(item)) {
                jl_array_ptr_1d_push(kept, item);
                continue;
            }
            jl_code_instance_t *ci = (jl_code_instance_t *)item;
            jl_value_t *src = jl_array_ptr_ref(all, ++i);
            auto part = by_mi.find(jl_get_ci_mi(ci));
            if (part != by_mi.end()) {
                jl_svec_t *entry = part->second;
                part_names[ci] = jl_string_data(jl_svecref(entry, 3));
                jl_array_ptr_1d_push(taken, (jl_value_t *)jl_svec(4, (jl_value_t *)ci, jl_svecref(entry, 1),
                                                                 jl_svecref(entry, 2), jl_svecref(entry, 3)));
                continue;
            }
            compiled[jl_get_ci_mi(ci)] = ci;
            jl_array_ptr_1d_push(kept, item);
            jl_array_ptr_1d_push(kept, src);
        }
        // The callee of each alias: the code instance that this image
        // compiles, else the one that the table names, else any of the method
        // instance, which a call through `jl_invoke` serves.
        jl_array_t *aliases = (jl_array_t *)jl_svecref(code_parts, 2);
        jl_array_t *resolved = jl_alloc_vec_any(0);
        fargs[3] = (jl_value_t *)resolved;
        for (size_t k = 0; k < jl_array_nrows(aliases); k++) {
            jl_svec_t *alias = (jl_svec_t *)jl_array_ptr_ref(aliases, k);
            jl_method_instance_t *mi = (jl_method_instance_t *)jl_svecref(alias, 0);
            jl_value_t *ci = jl_svecref(alias, 3);
            auto here = compiled.find(mi);
            if (here != compiled.end())
                ci = (jl_value_t *)here->second;
            else if (!jl_is_code_instance(ci))
                ci = (jl_value_t *)jl_atomic_load_relaxed(&mi->cache);
            if (ci == NULL || !jl_is_code_instance(ci))
                continue;
            jl_array_ptr_1d_push(resolved, (jl_value_t *)jl_svec(3, ci, jl_svecref(alias, 1), jl_svecref(alias, 2)));
        }
        codeinfos = (jl_value_t *)kept;
        code_parts = (jl_value_t *)jl_svec(3, (jl_value_t *)taken, jl_svecref(code_parts, 1), (jl_value_t *)resolved);
        fargs[4] = code_parts;
    }
    auto data = code_parts ?
        emit_native_code((jl_array_t*)codeinfos, (jl_array_t*)ci_order, llvmmod, NULL, external_linkage ? 1 : 0,
                         &part_names, code_parts) :
        (jl_native_code_desc_t *)jl_emit_native((jl_array_t*)codeinfos, (jl_array_t*)ci_order, llvmmod, NULL, external_linkage ? 1 : 0);
    JL_GC_POP();

    // move everything inside, now that we've merged everything
    // (before adding the exported headers)
    data->TSM_ref->withModuleDo([&](Module &M) {
        auto TT = Triple(M.getTargetTriple());
        Function *juliapersonality_func = nullptr;
        if (TT.isOSWindows() && TT.getArch() == Triple::x86_64) {
            // setting the function personality enables stack unwinding and catching exceptions
            // so make sure everything has something set
            Type *T_int32 = Type::getInt32Ty(M.getContext());
            juliapersonality_func = Function::Create(FunctionType::get(T_int32, true),
                Function::ExternalLinkage, "__julia_personality", M);
            juliapersonality_func->setDLLStorageClass(GlobalValue::DLLImportStorageClass);
        }
        for (GlobalObject &G : M.global_objects()) {
            if (!G.isDeclaration()) {
                if (isCoverageCounter(G)) {
                    // Coverage counters are referenced by name from the image
                    // coverage table in the separately-compiled metadata module,
                    // so they must stay visible across the image's objects.
                    G.setLinkage(GlobalValue::ExternalLinkage);
                    G.setVisibility(GlobalValue::HiddenVisibility);
                    G.setDSOLocal(true);
                    continue;
                }
                G.setLinkage(GlobalValue::InternalLinkage);
                G.setDSOLocal(true);
                makeSafeName(G);
                if (Function *F = dyn_cast<Function>(&G)) {
                    if (juliapersonality_func) {
                        // Add unwind exception personalities to functions to handle async exceptions
                        F->setPersonalityFn(juliapersonality_func);
                    }
                }
            }
        }
    });

    if (timed) {
        if (measure_compile_time_enabled) {
            auto end = jl_hrtime();
            jl_atomic_fetch_add_relaxed(&jl_cumulative_compile_time, end - compiler_start_time);
        }
        ct->reentrant_timing &= ~1ull;
    }
    return data;
}

// x16, x17 (ip0, ip1) are the intra-procedure-call scratch registers
const char *plt_asm_aarch64_macho =
    "adrp  x16, ${0}@page\n"
    "ldr   x16, [x16, ${0}@pageoff]\n"
    "br    x16\n";

const char *plt_asm_aarch64 =
    "adrp  x16, ${0}\n"
    "ldr   x16, [x16, :lo12:${0}]\n"
    "br    x16\n";

const char *plt_asm_x86_64 =
    "jmpq  *${0:a}\n";

const char *plt_asm_riscv64 =
    "1:  auipc t3, %pcrel_hi(${0})\n"
    "    ld    t3, %pcrel_lo(1b)(t3)\n"
    "    jalr  t1, t3";

const char *plt_asm_riscv32 =
    "1:  auipc t3, %pcrel_hi(${0})\n"
    "    lw    t3, %pcrel_lo(1b)(t3)\n"
    "    jalr  t1, t3";

// Emit a thunk that calls a compiled CodeInstance from an external image.
static Function *emit_pkg_plt_thunk(jl_codegen_output_t &out, jl_code_instance_t *ci,
                                    Function *CallSite)
{
    auto &M = out.get_module();
    auto &Ctx = out.get_context();
    Type *PtrTy = PointerType::getUnqual(Ctx);
    StringRef Name = name_from_method_instance(jl_get_ci_mi(ci));
    auto GVName = out.make_name(JL_SYM_JLPLT_GOT, Name);

    auto GV = new GlobalVariable(M, PtrTy, false, GlobalVariable::ExternalLinkage, nullptr,
                                 GVName);


    const char *Code = nullptr;
    auto OF = out.TargetTriple.getObjectFormat();
    if (out.TargetTriple.isAArch64()) {
        if (OF == Triple::MachO)
            Code = plt_asm_aarch64_macho;
        else
            Code = plt_asm_aarch64;
    }
    else if (out.TargetTriple.getArch() == Triple::x86_64) {
        Code = plt_asm_x86_64;
    }
    else if (out.TargetTriple.getArch() == Triple::riscv64) {
        Code = plt_asm_riscv64;
    }
    else if (out.TargetTriple.getArch() == Triple::riscv32) {
        Code = plt_asm_riscv32;
    }

    auto FTy = FunctionType::get(Type::getVoidTy(Ctx), !Code);
    auto F = Function::Create(FTy, Function::PrivateLinkage, 0,
                              out.make_name(JL_SYM_JLPLT, Name), &M);
    F->setCallingConv(CallSite->getCallingConv());
    AttrBuilder Attrs{Ctx};
    Attrs.addAttribute("frame-pointer", "none");
    Attrs.addAttribute("thunk");

    IRBuilder<> B{Ctx};
    auto BB = BasicBlock::Create(Ctx, "", F);
    B.SetInsertPoint(BB);

    if (Code) {
        Attrs.addAttribute(Attribute::Naked);
        Attrs.addAttribute(Attribute::NoInline);
        auto AsmTy = FunctionType::get(Type::getVoidTy(Ctx), {PtrTy}, false);
        auto Call = B.CreateCall(InlineAsm::get(AsmTy, Code, "s", true, false), {GV});
        Call->addFnAttr(Attribute::NoReturn);
        B.CreateUnreachable();
    }
    else {
        // Generic fallback that won't mangle registers, but may save and
        // restore all registers even when it isn't necessary.
        auto FPtr = B.CreateAlignedLoad(PtrTy, GV, out.DL.getPointerABIAlignment(0));
        auto Call = B.CreateCall(FTy, FPtr, {});
        Call->setTailCallKind(CallInst::TCK_MustTail);
        Call->setCallingConv(F->getCallingConv());
        B.CreateRetVoid();
    }
    F->addFnAttrs(Attrs);

    out.external_fns.emplace_back(ci, GV);
    return F;
}

typedef DenseMap<jl_method_instance_t*, SmallVector<jl_code_instance_t*, 1>> jl_compiled_by_mi_t;

static jl_compiled_functions_t::iterator get_ci_equiv_compiled(jl_code_instance_t *ci JL_PROPAGATES_ROOT, jl_compiled_functions_t &compiled_functions, jl_compiled_by_mi_t &by_mi) JL_NOTSAFEPOINT
{
    // equivalent CodeInstances have egal defs, so they share a MethodInstance
    jl_method_instance_t *mi = jl_get_ci_mi(ci);
    if (by_mi.empty()) {
        for (auto &it : compiled_functions)
            by_mi[jl_get_ci_mi(it.first)].push_back(it.first);
    }
    auto candidates = by_mi.find(mi);
    if (candidates != by_mi.end()) {
        for (jl_code_instance_t *codeinst : candidates->second) {
            if (codeinst != ci && jl_is_ci_equiv(ci, codeinst, 0))
                return compiled_functions.find(codeinst);
        }
    }
    return compiled_functions.end();
}

// Check the global cache for an equivalent CodeInstance with a world age range
// containing the world age range of the given CodeInstance.
static jl_code_instance_t *jl_get_ci_equiv_range(jl_code_instance_t *ci JL_PROPAGATES_ROOT) JL_NOTSAFEPOINT
{
    size_t target_min = jl_atomic_load_relaxed(&ci->min_world);
    size_t target_max = jl_atomic_load_relaxed(&ci->max_world);
    jl_value_t *def = ci->def;
    jl_method_instance_t *mi = jl_get_ci_mi(ci);
    jl_value_t *owner = ci->owner;
    jl_value_t *rettype = ci->rettype;
    jl_code_instance_t *codeinst = jl_atomic_load_relaxed(&mi->cache);
    while (codeinst) {
        if (codeinst != ci &&
            jl_atomic_load_relaxed(&codeinst->inferred) != NULL &&
            jl_atomic_load_relaxed(&codeinst->min_world) <= target_min &&
            jl_atomic_load_relaxed(&codeinst->max_world) >= target_max &&
            jl_egal(codeinst->def, def) &&
            jl_egal(codeinst->owner, owner) &&
            jl_egal(codeinst->rettype, rettype)) {
            return codeinst;
        }
        codeinst = jl_atomic_load_relaxed(&codeinst->next);
    }
    return ci;
}


// The place of each global value of `M`, which is the order of emission. The
// link of the calls and the tables of an image take this order, and not the
// order of the addresses of the code instances and of the objects: so two
// writes of the same code give the same image.
static DenseMap<const GlobalValue *, size_t> get_module_order(const Module &M) JL_NOTSAFEPOINT
{
    DenseMap<const GlobalValue *, size_t> order;
    for (const GlobalValue &G : M.global_values())
        order.try_emplace(&G, order.size());
    return order;
}

static size_t module_place(const DenseMap<const GlobalValue *, size_t> &order, const GlobalValue *G) JL_NOTSAFEPOINT
{
    auto it = G ? order.find(G) : order.end();
    return it == order.end() ? SIZE_MAX : it->second;
}

// Static version of JuliaOJIT::linkOutput
static void aot_link_output(jl_codegen_output_t &out) JL_CANSAFEPOINT
{
    jl_compiled_by_mi_t by_mi;
    auto order = get_module_order(out.get_module());
    SmallVector<std::pair<std::pair<jl_code_instance_t *, std::underlying_type_t<jl_invoke_api_t>>, jl_codegen_call_target_t>, 0>
        calls(out.call_targets.begin(), out.call_targets.end());
    llvm::stable_sort(calls, [&order](const auto &a, const auto &b) JL_NOTSAFEPOINT {
        return module_place(order, a.second.decl) < module_place(order, b.second.decl);
    });
    for (auto &[call, target] : calls) {
        auto [ci, api] = call;
        jl_code_instance_t *call_ci = ci;
        assert(api == JL_INVOKE_ARGS || api == JL_INVOKE_SPECSIG);
        JL_GC_PROMISE_ROOTED(ci);
        if (!target.decl->isDeclaration())
            continue;

        auto it = out.ci_funcs.find(ci);
        // Prefer a equivalent CodeInstance that we are compiling.
        if (it == out.ci_funcs.end()) {
            auto equiv = get_ci_equiv_compiled(ci, out.ci_funcs, by_mi);
            if (equiv != out.ci_funcs.end())
                it = equiv;
        }
        // A code instance of another part keeps its declaration, with the name
        // of the part: the link of the parts resolves it, as a direct call.
        if (it == out.ci_funcs.end() && out.part_names) {
            auto part = out.part_names->find(ci);
            if (part != out.part_names->end()) {
                target.decl->setName(part->second);
                target.decl->setLinkage(GlobalValue::ExternalLinkage);
                target.decl->setVisibility(GlobalValue::DefaultVisibility);
                out.part_calls.emplace_back(ci, (jl_invoke_api_t)api, target.decl->getName().str());
                continue;
            }
        }
        // If that fails, look for an equivalent CodeInstance that we can link to.
        if (it == out.ci_funcs.end() && out.external_linkage &&
            !(jl_atomic_load_relaxed(&ci->flags) & JL_CI_FLAGS_FROM_IMAGE))
            ci = jl_get_ci_equiv_range(ci);
        jl_codeinst_funcs_t<Value *> funcs;
        if (it != out.ci_funcs.end()) {
            funcs = {it->second.invoke_api, it->second.invoke, it->second.specptr};
        }
        else if (out.external_linkage && api == JL_INVOKE_SPECSIG &&
                 (jl_atomic_load_relaxed(&ci->flags) & JL_CI_FLAGS_FROM_IMAGE)) {
            Function *f = emit_pkg_plt_thunk(out, ci, target.decl);
            funcs = {JL_INVOKE_SPECSIG, nullptr, f};
        }
        else {
            Function *f = emit_tojlinvoke(ci, StringRef(), out);
            f->setLinkage(GlobalValue::InternalLinkage);
            funcs = {JL_INVOKE_ARGS, nullptr, f};
        }

        if (funcs.invoke_api != api) {
            assert(api == JL_INVOKE_SPECSIG); // Only possibility right now
            Function *f = emit_specsig_to_fptr1(out, ci, funcs.specptr);
            funcs.invoke_api = JL_INVOKE_SPECSIG;
            funcs.specptr = f;
        }

        // A name that a part of the store calls: an alias of the function of the
        // call, which the link of the part resolves.
        auto alias = out.part_aliases.find({call_ci, (jl_invoke_api_t)api});
        if (alias != out.part_aliases.end()) {
            auto GA = GlobalAlias::create(GlobalValue::ExternalLinkage, alias->second, cast<GlobalValue>(funcs.specptr));
            GA->setVisibility(GlobalValue::HiddenVisibility);
        }
        target.decl->replaceAllUsesWith(funcs.specptr);
        target.decl->eraseFromParent();
    }
}

static void jl_emit_native_to_output(jl_native_code_desc_t *data, jl_array_t *codeinfos,
                                      jl_array_t *ci_order, const jl_cgparams_t *cgparams,
                                      int external_linkage) JL_CANSAFEPOINT
{
    jl_cgparams_t target_cgparams = *cgparams;
    target_cgparams.sanitize_memory = jl_options.target_sanitize_memory;
    target_cgparams.sanitize_thread = jl_options.target_sanitize_thread;
    target_cgparams.sanitize_address = jl_options.target_sanitize_address;
    auto &out = *data->out;
    // record the caller-provided ordering of CodeInstances to store in the
    // image's method caches (see jl_get_llvm_mi_cache_order / jl_rewrite_mi_caches)
    if (ci_order) {
        size_t nci = jl_array_nrows(ci_order);
        data->jl_ci_order.reserve(nci);
        for (size_t k = 0; k < nci; k++) {
            jl_value_t *ci = jl_array_ptr_ref(ci_order, k);
            assert(jl_is_code_instance(ci));
            data->jl_ci_order.push_back((jl_code_instance_t*)ci);
        }
    }
    // compile all methods for the current world and type-inference world
    DenseMap<jl_code_instance_t *, jl_code_info_t *> ci_infos;
    egal_set method_roots;
    out.params = &target_cgparams;
    assert(out.imaging_mode); // `_imaging_mode` controls if broken features like code-coverage are disabled
    out.external_linkage = external_linkage;
    out.temporary_roots = jl_alloc_array_1d(jl_array_any_type, 0);
    bool safepoint_on_entry = out.safepoint_on_entry;
    JL_GC_PUSH3(&out.temporary_roots, &method_roots.list, &method_roots.keyset);
    size_t i, l;
    for (i = 0, l = jl_array_nrows(codeinfos); i < l; i++) {
        // each item in this list is either a CodeInstance followed by a CodeInfo indicating something
        // to compile, or a rettype followed by a sig describing a C-callable alias to create.
        jl_value_t *item = jl_array_ptr_ref(codeinfos, i);
        if (jl_is_code_instance(item)) {
            // now add it to our compilation results
            jl_code_instance_t *codeinst = (jl_code_instance_t*)item;

            if (external_linkage &&
                (jl_atomic_load_relaxed(&codeinst->flags) & JL_CI_FLAGS_FROM_IMAGE)) {
                ++i;
                continue;
            }

            jl_code_info_t *src = (jl_code_info_t*)jl_array_ptr_ref(codeinfos, ++i);
            assert(jl_is_code_info(src));
            ci_infos[codeinst] = src;
            if (jl_ir_inlining_cost((jl_value_t*)src) < UINT16_MAX)
                out.safepoint_on_entry = false; // ensure we don't block ExpandAtomicModifyPass from inlining this code if applicable
            if (out.ci_funcs.contains(codeinst))
                continue;       // TODO: make this an error
            if (!(out.params->force_emit_all) && jl_atomic_load_relaxed(&codeinst->invoke) == jl_fptr_const_return_addr)
                out.ci_funcs[codeinst] = {JL_INVOKE_CONST};
            else
                jl_emit_codeinst(out, codeinst, src);
            out.safepoint_on_entry = safepoint_on_entry;
            JL_GC_PROMISE_ROOTED(codeinst);
            record_method_roots(method_roots, jl_get_ci_mi(codeinst));
        }
        else {
            assert(jl_is_simplevector(item));
            jl_value_t *rt = jl_svecref(item, 0);
            jl_value_t *sig = jl_svecref(item, 1);
            jl_value_t *nameval = jl_svec_len(item) == 2 ? jl_nothing : jl_svecref(item, 2);
            assert(jl_is_type(rt) && jl_is_type(sig));
            jl_generate_ccallable(out, nameval, rt, sig);
        }
    }

    emit_always_inline(out,
                       [&ci_infos](jl_code_instance_t *ci) { return ci_infos.lookup(ci); });
    emit_llvmcall_modules(out);
    // The names that the parts of the store call and that this image defines.
    if (out.code_parts) {
        jl_array_t *aliases = (jl_array_t *)jl_svecref(out.code_parts, 2);
        for (size_t k = 0; k < jl_array_nrows(aliases); k++) {
            jl_svec_t *alias = (jl_svec_t *)jl_array_ptr_ref(aliases, k);
            jl_code_instance_t *ci = (jl_code_instance_t *)jl_svecref(alias, 0);
            auto api = (jl_invoke_api_t)jl_unbox_int32(jl_svecref(alias, 1));
            out.get_call_target(ci, api == JL_INVOKE_SPECSIG, false);
            out.part_aliases[{ci, api}] = jl_string_data(jl_svecref(alias, 2));
        }
    }
    // finally, make sure all referenced methods get fixed up, particularly if the user declined to compile them
    aot_link_output(out);
    // including generating cfunction thunks
    generate_cfunc_thunks(out);
    aot_optimize_roots(out, method_roots);
    out.temporary_roots = nullptr;
    out.temporary_roots_set.clear();
    ci_infos.clear();
    JL_GC_POP();

    CreateNativeMethods += out.ci_funcs.size();
    CreateNativeGlobals += out.global_targets.size();

    data->jl_value_to_llvm.reserve(out.global_targets.size());
    data->jl_sysimg_gvars.reserve(out.global_targets.size() + out.external_fns.size());

    // The tables of slots and of functions take the order of the module.
    Module &M = out.get_module();
    auto order = get_module_order(M);
    auto place = [&order](const GlobalValue *G) JL_NOTSAFEPOINT { return module_place(order, G); };
    SmallVector<std::pair<void *, GlobalVariable *>, 0> targets(out.global_targets.begin(), out.global_targets.end());
    llvm::stable_sort(targets, [&place](const auto &a, const auto &b) JL_NOTSAFEPOINT {
        return place(a.second) < place(b.second);
    });
    for (auto &[val, gv] : targets) {
        data->jl_value_to_llvm.push_back(val);
        data->jl_sysimg_gvars.push_back(gv);
    }
    // The slots of the parts of the store: the objects of the parts define
    // them, and the loader fills them with the values as all other slots.
    data->part_gvars_begin = data->part_gvars_end = data->jl_sysimg_gvars.size();
    if (out.code_parts) {
        jl_array_t *objects = (jl_array_t *)jl_svecref(out.code_parts, 1);
        Type *T_ptr = PointerType::getUnqual(M.getContext());
        for (size_t k = 0; k < jl_array_nrows(objects); k++) {
            jl_svec_t *object = (jl_svec_t *)jl_array_ptr_ref(objects, k);
            jl_array_t *bytes = (jl_array_t *)jl_svecref(object, 0);
            std::string prefix = jl_string_data(jl_svecref(object, 1));
            jl_array_t *slots = (jl_array_t *)jl_svecref(object, 2);
            for (size_t i = 0; i < jl_array_nrows(slots); i++) {
                auto gv = new GlobalVariable(M, T_ptr, false, GlobalValue::ExternalLinkage, nullptr,
                                             prefix + "#slot#" + std::to_string(i));
                data->jl_value_to_llvm.push_back(jl_array_ptr_ref(slots, i));
                data->jl_sysimg_gvars.push_back(gv);
            }
            data->part_objects.emplace_back(prefix + ".o",
                                            std::string(jl_array_data(bytes, char), jl_array_nrows(bytes)));
        }
        data->part_gvars_end = data->jl_sysimg_gvars.size();
    }
    for (auto &[ci, gv] : out.external_fns) {
        data->jl_sysimg_gvars.push_back(gv);
        data->jl_external_to_llvm.push_back(ci);
    }

    for (size_t i = 0; i < data->jl_sysimg_gvars.size(); i++) {
        if (data->part_gvars_begin <= i && i < data->part_gvars_end)
            continue;
        auto gv = (GlobalVariable *)data->jl_sysimg_gvars[i];
        gv->setInitializer(Constant::getNullValue(gv->getValueType()));
        gv->setLinkage(GlobalValue::InternalLinkage);
        gv->setDSOLocal(true);
    }

    data->jl_coverage_entries.reserve(out.image_coverage_counters.size());
    for (auto &covctr : out.image_coverage_counters) {
        uint32_t flags = covctr.second.second ? JL_IMAGE_COVERAGE_ENTRY_USER : 0;
        data->jl_coverage_entries.push_back({covctr.first.first, covctr.first.second, flags,
                                             covctr.second.first->getName().str()});
    }

    SmallVector<std::pair<jl_code_instance_t *, jl_llvm_functions_t>, 0> ci_funcs(out.ci_funcs.begin(), out.ci_funcs.end());
    auto first_place = [&place](const jl_llvm_functions_t &funcs) JL_NOTSAFEPOINT {
        return std::min(place(funcs.invoke), place(funcs.specptr));
    };
    llvm::stable_sort(ci_funcs, [&first_place](const auto &a, const auto &b) JL_NOTSAFEPOINT {
        return first_place(a.second) < first_place(b.second);
    });
    for (auto &[ci, funcs] : ci_funcs) {
        uint32_t invoke_id, specptr_id = 0;
        if (funcs.invoke_api == JL_INVOKE_SPECSIG) {
            assert(funcs.invoke);
            data->jl_sysimg_fvars.push_back(funcs.invoke);
            invoke_id = data->jl_sysimg_fvars.size();
        } else {
            invoke_id = -funcs.invoke_api;
        }
        if (funcs.specptr) {
            data->jl_sysimg_fvars.push_back(funcs.specptr);
            specptr_id = data->jl_sysimg_fvars.size();
        }
        data->jl_fvar_map[ci] = {invoke_id, specptr_id};
    }
    // The functions of the parts of the store: the objects of the parts define
    // them, and each code instance gets their indexes as a compiled one does.
    data->part_fvars_begin = data->part_fvars_end = data->jl_sysimg_fvars.size();
    if (out.code_parts) {
        jl_array_t *functions = (jl_array_t *)jl_svecref(out.code_parts, 0);
        FunctionType *FT = FunctionType::get(Type::getVoidTy(M.getContext()), false);
        auto declare = [&](const char *name) -> GlobalValue * {
            return cast<GlobalValue>(M.getOrInsertFunction(name, FT).getCallee());
        };
        for (size_t k = 0; k < jl_array_nrows(functions); k++) {
            jl_svec_t *entry = (jl_svec_t *)jl_array_ptr_ref(functions, k);
            jl_code_instance_t *ci = (jl_code_instance_t *)jl_svecref(entry, 0);
            auto api = (jl_invoke_api_t)jl_unbox_int32(jl_svecref(entry, 1));
            uint32_t invoke_id, specptr_id;
            if (api == JL_INVOKE_SPECSIG) {
                data->jl_sysimg_fvars.push_back(declare(jl_string_data(jl_svecref(entry, 2))));
                invoke_id = data->jl_sysimg_fvars.size();
            } else {
                invoke_id = -api;
            }
            data->jl_sysimg_fvars.push_back(declare(jl_string_data(jl_svecref(entry, 3))));
            specptr_id = data->jl_sysimg_fvars.size();
            data->jl_fvar_map[ci] = {invoke_id, specptr_id};
        }
        data->part_fvars_end = data->jl_sysimg_fvars.size();
    }
}

// also be used by extern consumers like GPUCompiler.jl to obtain a module containing
// all reachable & inferrrable functions.
extern "C" JL_DLLEXPORT_CODEGEN
void *jl_emit_native_impl(jl_array_t *codeinfos, jl_array_t *ci_order, LLVMOrcThreadSafeModuleRef llvmmod, const jl_cgparams_t *cgparams, int external_linkage)
{
    return (void *)emit_native_code(codeinfos, ci_order, llvmmod, cgparams, external_linkage, nullptr);
}

static jl_native_code_desc_t *emit_native_code(jl_array_t *codeinfos, jl_array_t *ci_order, LLVMOrcThreadSafeModuleRef llvmmod,
                                          const jl_cgparams_t *cgparams, int external_linkage,
                                          const DenseMap<jl_code_instance_t *, std::string> *part_names,
                                          jl_value_t *code_parts)
{
    JL_TIMING(NATIVE_AOT, NATIVE_Create);
    ++CreateNativeCalls;
    CreateNativeMax.updateMax(jl_array_nrows(codeinfos));
    if (cgparams == NULL)
        cgparams = &jl_default_cgparams;
    jl_native_code_desc_t *data = new jl_native_code_desc_t;
    if (llvmmod) {
        data->TSM_ref = unwrap(llvmmod);
    } else {
        const DataLayout &DL = jl_ExecutionEngine->getDataLayout();
        const Triple &triple = jl_ExecutionEngine->getTargetTriple();
        auto ctx = std::make_unique<LLVMContext>();
        auto M = jl_create_llvm_module("text", *ctx, DL, triple);
        ctx->setDiscardValueNames(true);
        data->TSM = orc::ThreadSafeModule(std::move(M), std::move(ctx));
        data->TSM_ref = &data->TSM;
    }

    data->TSM_ref->withModuleDo([&](Module &M) JL_CANSAFEPOINT {
        data->out = std::make_unique<jl_codegen_output_t>(M);
        data->out->part_names = part_names;
        data->out->code_parts = code_parts;
        jl_emit_native_to_output(data, codeinfos, ci_order, cgparams, external_linkage);
    });

    return data;
}

static object::Archive::Kind getDefaultForHost(Triple &triple)
{
      if (triple.isOSDarwin())
          return object::Archive::K_DARWIN;
      return object::Archive::K_GNU;
}

typedef Error ArchiveWriterError;
static void reportWriterError(const ErrorInfoBase &E)
{
    std::string err = E.message();
    jl_safe_printf("ERROR: failed to emit output file %s\n", err.c_str());
}

static void injectCRTAlias(Module &M, StringRef name, StringRef alias, FunctionType *FT)
{
    Function *target = M.getFunction(alias);
    if (!target) {
        target = Function::Create(FT, Function::ExternalLinkage, alias, M);
    }
    Function *interposer = Function::Create(FT, Function::InternalLinkage, name, M);
    appendToCompilerUsed(M, {interposer});

    llvm::IRBuilder<> builder(BasicBlock::Create(M.getContext(), "top", interposer));
    SmallVector<Value *, 4> CallArgs;
    for (auto &arg : interposer->args())
        CallArgs.push_back(&arg);
    auto val = builder.CreateCall(target, CallArgs);
    builder.CreateRet(val);
}

// The tables of the shard of the parts of a store (`jl_set_code_parts`), with
// the suffix of the shard `index`: the objects of the parts define the
// functions and the slots, and the link of the image resolves the names. The
// parts have one target, so the clone tables are empty.
static void emit_parts_shard(Module &M, Type *T_size, unsigned index,
                             ArrayRef<std::pair<std::string, uint32_t>> fvars,
                             ArrayRef<std::pair<std::string, uint32_t>> gvars)
{
    auto &Context = M.getContext();
    auto suffix = "_" + std::to_string(index);
    Type *T_ptr = PointerType::getUnqual(Context);
    Type *T_int32 = Type::getInt32Ty(Context);
    auto hide = [](GlobalVariable *gv) {
        gv->setVisibility(GlobalValue::HiddenVisibility);
        gv->setDSOLocal(true);
    };
    FunctionType *FT = FunctionType::get(Type::getVoidTy(Context), false);
    SmallVector<Constant *, 0> fptrs;
    SmallVector<uint32_t, 0> fidxs;
    for (auto &[name, idx] : fvars) {
        fptrs.push_back(cast<Constant>(M.getOrInsertFunction(name, FT).getCallee()));
        fidxs.push_back(idx);
    }
    hide(new GlobalVariable(M, T_size, true, GlobalValue::ExternalLinkage,
                            ConstantInt::get(T_size, fptrs.size()), "jl_fvar_count" + suffix));
    auto fptrs_type = ArrayType::get(T_ptr, fptrs.size());
    hide(new GlobalVariable(M, fptrs_type, false, GlobalValue::ExternalLinkage,
                            ConstantArray::get(fptrs_type, fptrs), "jl_fvar_ptrs" + suffix));
    hide(new GlobalVariable(M, ArrayType::get(T_int32, fidxs.size()), true, GlobalValue::ExternalLinkage,
                            ConstantDataArray::get(Context, fidxs), "jl_fvar_idxs" + suffix));
    SmallVector<Constant *, 0> slots;
    SmallVector<uint32_t, 0> gidxs;
    for (auto &[name, idx] : gvars) {
        slots.push_back(cast<Constant>(M.getOrInsertGlobal(name, T_ptr)));
        gidxs.push_back(idx);
    }
    emit_offset_table(M, T_size, slots, "jl_gvar", suffix);
    hide(new GlobalVariable(M, ArrayType::get(T_int32, gidxs.size()), true, GlobalValue::ExternalLinkage,
                            ConstantDataArray::get(Context, gidxs), "jl_gvar_idxs" + suffix));
    SmallVector<uint32_t, 1> no_slots{0};
    hide(new GlobalVariable(M, ArrayType::get(T_int32, 1), true, GlobalValue::ExternalLinkage,
                            ConstantDataArray::get(Context, no_slots), "jl_clone_slots" + suffix));
    SmallVector<uint32_t, 1> no_clones{jl_sysimg_tag_mask};
    hide(new GlobalVariable(M, ArrayType::get(T_int32, 1), true, GlobalValue::ExternalLinkage,
                            ConstantDataArray::get(Context, no_clones), "jl_clone_idxs" + suffix));
    auto no_ptrs = ArrayType::get(T_ptr, 0);
    hide(new GlobalVariable(M, no_ptrs, true, GlobalValue::ExternalLinkage,
                            ConstantArray::get(no_ptrs, {}), "jl_clone_ptrs" + suffix));
}

// See src/processor.h for documentation about this table. Corresponds to jl_image_shard_t.
static GlobalVariable *emit_shard_table(Module &M, Type *T_size, Type *T_psize, unsigned threads) {
    SmallVector<Constant *, 0> tables(sizeof(jl_image_shard_t) / sizeof(void *) * threads);
    for (unsigned i = 0; i < threads; i++) {
        auto suffix = "_" + std::to_string(i);
        auto create_gv = [&](StringRef name, bool constant) -> GlobalVariable * {
            // The shard of the parts of a store has its tables in this module.
            if (auto gv = M.getNamedGlobal((name + suffix).str()))
                return gv;
            auto gv = new GlobalVariable(M, T_size, constant,
                                         GlobalValue::ExternalLinkage, nullptr, name + suffix);
            gv->setVisibility(GlobalValue::HiddenVisibility);
            gv->setDSOLocal(true);
            return gv;
        };
        auto table = tables.data() + i * sizeof(jl_image_shard_t) / sizeof(void *);
        table[offsetof(jl_image_shard_t, fvar_count) / sizeof(void*)] = create_gv("jl_fvar_count", true);
        table[offsetof(jl_image_shard_t, fvar_ptrs) / sizeof(void*)] = create_gv("jl_fvar_ptrs", true);
        table[offsetof(jl_image_shard_t, fvar_idxs) / sizeof(void*)] = create_gv("jl_fvar_idxs", true);
        table[offsetof(jl_image_shard_t, gvar_offsets) / sizeof(void*)] = create_gv("jl_gvar_offsets", true);
        table[offsetof(jl_image_shard_t, gvar_idxs) / sizeof(void*)] = create_gv("jl_gvar_idxs", true);
        table[offsetof(jl_image_shard_t, clone_slots) / sizeof(void*)] = create_gv("jl_clone_slots", true);
        table[offsetof(jl_image_shard_t, clone_ptrs) / sizeof(void*)] = create_gv("jl_clone_ptrs", true);
        table[offsetof(jl_image_shard_t, clone_idxs) / sizeof(void*)] = create_gv("jl_clone_idxs", true);
    }
    auto tables_arr = ConstantArray::get(ArrayType::get(T_psize, tables.size()), tables);
    auto tables_gv = new GlobalVariable(M, tables_arr->getType(), false,
                                        GlobalValue::ExternalLinkage, tables_arr, "jl_shard_tables");
    tables_gv->setVisibility(GlobalValue::HiddenVisibility);
    tables_gv->setDSOLocal(true);
    return tables_gv;
}

static Function *emit_pgcstack_default_func(Module &M, Type *T_ptr) {
    auto FT = FunctionType::get(T_ptr, false);
    auto F = Function::Create(FT, GlobalValue::InternalLinkage, "pgcstack_default_func", &M);
    llvm::IRBuilder<> builder(BasicBlock::Create(M.getContext(), "top", F));
    builder.CreateRet(Constant::getNullValue(T_ptr));
    return F;
}

// See src/processor.h for documentation about this table. Corresponds to jl_image_ptls_t.
static GlobalVariable *emit_ptls_table(Module &M, Type *T_size, Type *T_ptr) {
    std::array<Constant *, 3> ptls_table{
        new GlobalVariable(M, T_ptr, false, GlobalValue::ExternalLinkage, emit_pgcstack_default_func(M, T_ptr), "jl_pgcstack_func_slot"),
        new GlobalVariable(M, T_size, false, GlobalValue::ExternalLinkage, Constant::getNullValue(T_size), "jl_pgcstack_key_slot"),
        new GlobalVariable(M, T_size, false, GlobalValue::ExternalLinkage, Constant::getAllOnesValue(T_size), "jl_image_tls_offset"),
    };
    for (auto &gv : ptls_table) {
        cast<GlobalVariable>(gv)->setVisibility(GlobalValue::HiddenVisibility);
        cast<GlobalVariable>(gv)->setDSOLocal(true);
    }
    auto ptls_table_arr = ConstantArray::get(ArrayType::get(T_ptr, ptls_table.size()), ptls_table);
    auto ptls_table_gv = new GlobalVariable(M, ptls_table_arr->getType(), false,
                                            GlobalValue::ExternalLinkage, ptls_table_arr, "jl_ptls_table");
    ptls_table_gv->setVisibility(GlobalValue::HiddenVisibility);
    ptls_table_gv->setDSOLocal(true);
    return ptls_table_gv;
}

// See src/processor.h for documentation about this table. Corresponds to jl_image_header_t.
static GlobalVariable *emit_image_header(Module &M, unsigned threads, unsigned nfvars, unsigned ngvars) {
    constexpr uint32_t version = 1;
    std::array<uint32_t, 4> header{
        version,
        threads,
        nfvars,
        ngvars,
    };
    auto header_arr = ConstantDataArray::get(M.getContext(), header);
    auto header_gv = new GlobalVariable(M, header_arr->getType(), false,
                                        GlobalValue::InternalLinkage, header_arr, "jl_image_header");
    return header_gv;
}

// Grab fvars and gvars data from the module
static void get_fvars_gvars(Module &M, DenseMap<GlobalValue *, unsigned> &fvars, DenseMap<GlobalValue *, unsigned> &gvars) {
    auto fvars_gv = M.getGlobalVariable("jl_fvars");
    auto gvars_gv = M.getGlobalVariable("jl_gvars");
    auto fvars_idxs = M.getGlobalVariable("jl_fvar_idxs");
    auto gvars_idxs = M.getGlobalVariable("jl_gvar_idxs");
    assert(fvars_gv);
    assert(gvars_gv);
    assert(fvars_idxs);
    assert(gvars_idxs);
    auto fvars_init = fvars_gv->getInitializer();
    auto gvars_init = gvars_gv->getInitializer();
    // The index of an entry in the whole image: the slots and the functions of
    // the parts of a store are in a shard of their own, so the indexes can
    // have gaps.
    auto fidxs = cast<ConstantDataArray>(fvars_idxs->getInitializer());
    auto gidxs = cast<ConstantDataArray>(gvars_idxs->getInitializer());
    for (unsigned i = 0; i < fvars_init->getNumOperands(); ++i) {
        auto gv = cast<GlobalValue>(fvars_init->getOperand(i)->stripPointerCasts());
        assert(gv && gv->hasName() && "fvar must be a named global");
        assert(!fvars.count(gv) && "Duplicate fvar");
        fvars[gv] = fidxs->getElementAsInteger(i);
    }
    assert(fvars.size() == fvars_init->getNumOperands());
    for (unsigned i = 0; i < gvars_init->getNumOperands(); ++i) {
        auto gv = cast<GlobalValue>(gvars_init->getOperand(i)->stripPointerCasts());
        assert(gv && gv->hasName() && "gvar must be a named global");
        assert(!gvars.count(gv) && "Duplicate gvar");
        gvars[gv] = gidxs->getElementAsInteger(i);
    }
    assert(gvars.size() == gvars_init->getNumOperands());
    fvars_gv->eraseFromParent();
    gvars_gv->eraseFromParent();
    fvars_idxs->eraseFromParent();
    gvars_idxs->eraseFromParent();
}

// Weight computation
// It is important for multithreaded image building to be able to split work up
// among the threads equally. The weight calculated here is an estimation of
// how expensive a particular function is going to be to compile.

namespace {
struct FunctionInfo {
    size_t weight;
    size_t bbs;
    size_t insts;
    size_t clones;
};
}  // anonymous namespace

static FunctionInfo getFunctionWeight(const Function &F)
{
    FunctionInfo info;
    info.weight = 1;
    info.bbs = F.size();
    info.insts = 0;
    info.clones = 1;
    for (const BasicBlock &BB : F) {
        info.insts += BB.size();
    }
    if (F.hasFnAttribute("julia.mv.clones")) {
        auto val = F.getFnAttribute("julia.mv.clones").getValueAsString();
        // base16, so must be at most 4 * length bits long
        // popcount gives number of clones
        info.clones = APInt(val.size() * 4, val, 16).popcount() + 1;
    }
    info.weight += info.insts;
    // more basic blocks = more complex than just sum of insts,
    // add some weight to it
    info.weight += info.bbs;
    info.weight *= info.clones;
    return info;
}

namespace {
struct ModuleInfo {
    size_t globals;
    size_t funcs;
    size_t bbs;
    size_t insts;
    size_t clones;
    size_t weight;
};
}  // anonymous namespace

static ModuleInfo compute_module_info(Module &M) {
    ModuleInfo info;
    info.globals = 0;
    info.funcs = 0;
    info.bbs = 0;
    info.insts = 0;
    info.clones = 0;
    info.weight = 0;
    for (auto &G : M.global_values()) {
        if (G.isDeclaration()) {
            continue;
        }
        info.globals++;
        if (auto F = dyn_cast<Function>(&G)) {
            info.funcs++;
            auto func_info = getFunctionWeight(*F);
            info.bbs += func_info.bbs;
            info.insts += func_info.insts;
            info.clones += func_info.clones;
            info.weight += func_info.weight;
        } else {
            info.weight += 1;
        }
    }
    return info;
}

namespace {
struct Partition {
    StringMap<bool> globals;
    StringMap<unsigned> fvars;
    StringMap<unsigned> gvars;
    size_t weight;
};
}  // anonymous namespace

static inline bool verify_partitioning(const SmallVectorImpl<Partition> &partitions, const Module &M, DenseMap<GlobalValue *, unsigned> &fvars, DenseMap<GlobalValue *, unsigned> &gvars) {
    bool bad = false;
#ifndef JL_NDEBUG
    // The indexes can have gaps, where the shard of the parts of a store is.
    size_t fvars_size = 0;
    size_t gvars_size = 0;
    for (auto &var : fvars)
        fvars_size = std::max<size_t>(fvars_size, var.second + 1);
    for (auto &var : gvars)
        gvars_size = std::max<size_t>(gvars_size, var.second + 1);
    SmallVector<uint32_t, 0> fvars_partition(fvars_size);
    SmallVector<uint32_t, 0> gvars_partition(gvars_size);
    StringMap<uint32_t> GVNames;
    for (uint32_t i = 0; i < partitions.size(); i++) {
        for (auto &name : partitions[i].globals) {
            if (GVNames.count(name.getKey())) {
                bad = true;
                dbgs() << "Duplicate global name " << name.getKey() << " in partitions " << i << " and " << GVNames[name.getKey()] << "\n";
            }
            GVNames[name.getKey()] = i;
        }
        for (auto &fvar : partitions[i].fvars) {
            if (fvars_partition[fvar.second] != 0) {
                bad = true;
                dbgs() << "Duplicate fvar " << fvar.first() << " in partitions " << i << " and " << fvars_partition[fvar.second] - 1 << "\n";
            }
            fvars_partition[fvar.second] = i+1;
        }
        for (auto &gvar : partitions[i].gvars) {
            if (gvars_partition[gvar.second] != 0) {
                bad = true;
                dbgs() << "Duplicate gvar " << gvar.first() << " in partitions " << i << " and " << gvars_partition[gvar.second] - 1 << "\n";
            }
            gvars_partition[gvar.second] = i+1;
        }
    }
    for (auto &GV : M.global_values()) {
        if (GV.isDeclaration()) {
            if (GVNames.count(GV.getName())) {
                bad = true;
                dbgs() << "Global " << GV.getName() << " is a declaration but is in partition " << GVNames[GV.getName()] << "\n";
            }
        } else {
            // Local global values are not partitioned
            if (!GVNames.count(GV.getName())) {
                bad = true;
                dbgs() << "Global " << GV << " not in any partition\n";
            }
            for (ConstantUses<GlobalValue> uses(const_cast<GlobalValue*>(&GV), const_cast<Module&>(M)); !uses.done(); uses.next()) {
                auto val = uses.get_info().val;
                if (!GVNames.count(val->getName())) {
                    bad = true;
                    dbgs() << "Global " << val->getName() << " used by " << GV.getName() << ", which is not in any partition\n";
                    continue;
                }
                if (GVNames[val->getName()] != GVNames[GV.getName()]) {
                    // coverage counters are shared across partitions by design
                    if (isCoverageCounter(GV) || isCoverageCounter(*val))
                        continue;
                    bad = true;
                    dbgs() << "Global " << val->getName() << " used by " << GV.getName() << ", which is in partition " << GVNames[GV.getName()] << " but " << val->getName() << " is in partition " << GVNames[val->getName()] << "\n";
                }
            }
        }
    }
    for (auto &var : fvars) {
        if (fvars_partition[var.second] == 0) {
            bad = true;
            dbgs() << "fvar " << var.first->getName() << " at " << var.second << " not in any partition\n";
        }
    }
    for (auto &var : gvars) {
        if (gvars_partition[var.second] == 0) {
            bad = true;
            dbgs() << "gvar " << var.second << " not in any partition\n";
        }
    }
#endif
    return !bad;
}

// Chop a module up as equally as possible by weight into threads partitions
static SmallVector<Partition, 32> partitionModule(Module &M, unsigned threads) {
    //Start by stripping fvars and gvars, which helpfully removes their uses as well
    DenseMap<GlobalValue *, unsigned> fvars, gvars;
    get_fvars_gvars(M, fvars, gvars);

    // Partition by union-find, since we only have def->use traversal right now
    struct Partitioner {
        struct Node {
            GlobalValue *GV;
            unsigned parent;
            unsigned size;
            size_t weight;
        };
        SmallVector<Node, 0> nodes;
        DenseMap<GlobalValue *, unsigned> node_map;
        unsigned merged;

        unsigned make(GlobalValue *GV, size_t weight) {
            unsigned idx = nodes.size();
            nodes.push_back({GV, idx, 1, weight});
            node_map[GV] = idx;
            return idx;
        }

        unsigned find(unsigned idx) {
            while (nodes[idx].parent != idx) {
                nodes[idx].parent = nodes[nodes[idx].parent].parent;
                idx = nodes[idx].parent;
            }
            return idx;
        }

        unsigned merge(unsigned x, unsigned y) {
            x = find(x);
            y = find(y);
            if (x == y)
                return x;
            if (nodes[x].size < nodes[y].size)
                std::swap(x, y);
            nodes[y].parent = x;
            nodes[x].size += nodes[y].size;
            nodes[x].weight += nodes[y].weight;
            merged++;
            return x;
        }
    };

    Partitioner partitioner;

    for (auto &G : M.global_values()) {
        if (G.isDeclaration())
            continue;
        // Coverage counters are shared by commonly inlined code, so
        // partitioning them together with their users would collapse most of
        // the module into a single partition. Skip them here; they are
        // assigned round-robin once the code partitions are settled.
        if (isCoverageCounter(G))
            continue;
        // Currently ccallable global aliases have extern linkage, we only want to make the
        // internally linked functions/global variables extern+hidden
        if (G.hasLocalLinkage()) {
            G.setLinkage(GlobalValue::ExternalLinkage);
            G.setVisibility(GlobalValue::HiddenVisibility);
        }
        if (auto F = dyn_cast<Function>(&G)) {
            partitioner.make(&G, getFunctionWeight(*F).weight);
        }
        else {
            partitioner.make(&G, 1);
        }
    }

    // Merge all uses to go together into the same partition
    for (unsigned i = 0; i < partitioner.nodes.size(); ++i) {
        for (ConstantUses<GlobalValue> uses(partitioner.nodes[i].GV, M); !uses.done(); uses.next()) {
            auto val = uses.get_info().val;
            auto idx = partitioner.node_map.find(val);
            if (idx == partitioner.node_map.end()) {
                // only coverage counters are deliberately left out of the
                // partitioning above; anything else is a global that
                // partitionModule failed to account for
                assert(isCoverageCounter(*val) && "unpartitioned global that is not a coverage counter");
                continue;
            }
            partitioner.merge(i, idx->second);
        }
    }

    SmallVector<Partition, 32> partitions(threads);
    // always get the smallest partition first
    auto pcomp = [](const Partition *p1, const Partition *p2) {
        return p1->weight > p2->weight;
    };
    std::priority_queue<Partition *, SmallVector<Partition *, 0>, decltype(pcomp)> pq(pcomp);
    for (unsigned i = 0; i < threads; ++i) {
        pq.push(&partitions[i]);
    }

    SmallVector<unsigned, 0> idxs(partitioner.nodes.size());
    std::iota(idxs.begin(), idxs.end(), 0);
    std::sort(idxs.begin(), idxs.end(), [&](unsigned a, unsigned b) {
        //because roots have more weight than their children,
        //we can sort by weight and get the roots first
        return partitioner.nodes[a].weight > partitioner.nodes[b].weight;
    });

    // Assign the root of each partition to a partition, then assign its children to the same one
    for (unsigned idx = 0; idx < idxs.size(); ++idx) {
        auto i = idxs[idx];
        auto root = partitioner.find(i);
        assert(root == i || partitioner.nodes[root].weight == 0);
        if (partitioner.nodes[root].weight) {
            auto &node = partitioner.nodes[root];
            auto &P = *pq.top();
            pq.pop();
            auto name = node.GV->getName();
            P.globals.insert({name, true});
            if (fvars.count(node.GV))
                P.fvars[name] = fvars[node.GV];
            if (gvars.count(node.GV))
                P.gvars[name] = gvars[node.GV];
            P.weight += node.weight;
            node.weight = 0;
            node.size = &P - partitions.data();
            pq.push(&P);
        }
        if (root != i) {
            auto &node = partitioner.nodes[i];
            assert(node.weight != 0);
            // we assigned its root already, so just add it to the root's partition
            // don't touch the priority queue, since we're not changing the weight
            auto &P = partitions[partitioner.nodes[root].size];
            auto name = node.GV->getName();
            P.globals.insert({name, true});
            if (fvars.count(node.GV))
                P.fvars[name] = fvars[node.GV];
            if (gvars.count(node.GV))
                P.gvars[name] = gvars[node.GV];
            node.weight = 0;
            node.size = partitioner.nodes[root].size;
        }
    }

    // Assign the coverage counters that were skipped above, now that the code
    // partitions are settled. Any partition works: the counters are external
    // hidden symbols, so cross-partition references resolve at link time.
    for (auto &G : M.globals()) {
        if (G.isDeclaration() || !isCoverageCounter(G))
            continue;
        auto &P = *pq.top();
        pq.pop();
        P.globals.insert({G.getName(), true});
        P.weight += 1;
        pq.push(&P);
    }

    bool verified = verify_partitioning(partitions, M, fvars, gvars);
    if (!verified)
        llvm_dump(&M);
    assert(verified && "Partitioning failed to partition globals correctly");
    (void) verified;

    return partitions;
}

namespace {
struct ImageTimer {
    uint64_t elapsed = 0;
    std::string name;
    std::string desc;
#ifdef USE_TRACY
    TracyCZoneCtx tracy_ctx;
#endif

    void startTimer() {
        elapsed = jl_hrtime();
#ifdef USE_TRACY
        // Emit a Tracy zone for this stage. The AOT image shards run on libuv
        // worker threads that lack a Julia task/ptls, so JL_TIMING cannot be
        // used here; the raw Tracy C API works on any thread. `desc` is used as
        // the zone name so stages aggregate across shards (the shard is
        // distinguished by the named worker thread).
        uint64_t srcloc = ___tracy_alloc_srcloc_name(
            __LINE__, __FILE__, sizeof(__FILE__) - 1,
            "add_output", sizeof("add_output") - 1,
            desc.c_str(), desc.size(), 0);
        tracy_ctx = ___tracy_emit_zone_begin_alloc(srcloc, 1);
#endif
    }

    void stopTimer() {
        elapsed = jl_hrtime() - elapsed;
#ifdef USE_TRACY
        ___tracy_emit_zone_end(tracy_ctx);
#endif
    }

    void init(const Twine &name, const Twine &desc) {
        this->name = name.str();
        this->desc = desc.str();
    }

    operator bool() const {
        return elapsed != 0;
    }

    void print(raw_ostream &out, bool clear=false) {
        if (!*this)
            return;
        out << llvm::formatv("{0:F3}  ", elapsed / 1e9) << name << "  " << desc << "\n";
        if (clear)
            elapsed = 0;
    }
};
}  // anonymous namespace

namespace {
struct ShardTimers {
    ImageTimer deserialize;
    ImageTimer materialize;
    ImageTimer construct;
    // impl timers
    ImageTimer unopt;
    ImageTimer optimize;
    ImageTimer opt;
    ImageTimer obj;
    ImageTimer asm_;

    std::string name;
    std::string desc;

    void print(raw_ostream &out, bool clear=false) {
        StringRef sep = "===-------------------------------------------------------------------------===";
        out << formatv("{0}\n{1}\n{0}\n", sep, fmt_align(name + " : " + desc, AlignStyle::Center, sep.size()));
        auto total = deserialize.elapsed + materialize.elapsed + construct.elapsed +
            unopt.elapsed + optimize.elapsed + opt.elapsed + obj.elapsed + asm_.elapsed;
        out << "Time (s)  Name  Description\n";
        deserialize.print(out, clear);
        materialize.print(out, clear);
        construct.print(out, clear);
        unopt.print(out, clear);
        optimize.print(out, clear);
        opt.print(out, clear);
        obj.print(out, clear);
        asm_.print(out, clear);
        out << llvm::formatv("{0:F3}  total  Total time taken\n", total / 1e9);
    }
};
}  // anonymous namespace

namespace {
struct AOTOutputs {
    SmallVector<char, 0> unopt, opt, obj, asm_;
};
}  // anonymous namespace

static void emit_bitcode(Module &M, TargetMachine &TM, SmallVectorImpl<char> &buf)
{
    raw_svector_ostream OS(buf);
    PassBuilder PB;
    AnalysisManagers AM{TM, PB, OptimizationLevel::O0};
    ModulePassManager MPM;
    MPM.addPass(BitcodeWriterPass(OS));
    MPM.run(M, AM.MAM);
}

static void emit_native(Module &M, TargetMachine &TM, SmallVectorImpl<char> &buf, bool asm_)
{
    jl_fpctrl_default_scope fpctrl_scope;
    raw_svector_ostream OS(buf);
    legacy::PassManager emitter;
    addTargetPasses(&emitter, TM.getTargetTriple(), TM.getTargetIRAnalysis());
    auto type = asm_ ? CodeGenFileType::AssemblyFile : CodeGenFileType::ObjectFile;
    if (TM.addPassesToEmitFile(emitter, OS, nullptr, type, false))
        jl_safe_printf("ERROR: target does not support generation of %s files\n",
                       asm_ ? "assembly" : "object");
    emitter.run(M);
}

// Perform the actual optimization and emission of the output files
static AOTOutputs add_output_impl(Module &M, TargetMachine &SourceTM, ShardTimers &timers,
        bool unopt, bool opt, bool obj, bool asm_) {
    assert((unopt || opt || obj || asm_) && "no output requested");
    AOTOutputs out;
    auto TM = std::unique_ptr<TargetMachine>(
        SourceTM.getTarget().createTargetMachine(
            SourceTM.getTargetTriple(),
            SourceTM.getTargetCPU(),
            SourceTM.getTargetFeatureString(),
            SourceTM.Options,
            SourceTM.getRelocationModel(),
            SourceTM.getCodeModel(),
            SourceTM.getOptLevel()));
    fixupTM(*TM);
    if (unopt) {
        timers.unopt.startTimer();
        emit_bitcode(M, *TM, out.unopt);
        timers.unopt.stopTimer();
    }
    if (!opt && !obj && !asm_) {
        return out;
    }
    assert(!verifyLLVMIR(M));

    {
        timers.optimize.startTimer();

        auto PMTM = std::unique_ptr<TargetMachine>(
            SourceTM.getTarget().createTargetMachine(
                SourceTM.getTargetTriple(),
                SourceTM.getTargetCPU(),
                SourceTM.getTargetFeatureString(),
                SourceTM.Options,
                SourceTM.getRelocationModel(),
                SourceTM.getCodeModel(),
                SourceTM.getOptLevel()));
        fixupTM(*PMTM);
        auto options = OptimizationOptions::defaults(true, true);
        options.sanitize_memory = jl_options.target_sanitize_memory;
        options.sanitize_thread = jl_options.target_sanitize_thread;
        options.sanitize_address = jl_options.target_sanitize_address;
        NewPM optimizer{std::move(PMTM), getOptLevel(jl_options.opt_level), options};
        {
            TimeTraceScope OptimizeScope("AOT Optimize", M.getModuleIdentifier());
            optimizer.run(M);
        }
        assert(!verifyLLVMIR(M));
        bool inject_aliases = false;
        for (auto &F : M.functions()) {
            if (!F.isDeclaration() && F.getName() != "_DllMainCRTStartup") {
                inject_aliases = true;
                break;
            }
        }
        // no need to inject aliases if we have no functions

        if (inject_aliases) {
            // We would like to emit an alias or an weakref alias to redirect these symbols
            // but LLVM doesn't let us emit a GlobalAlias to a declaration...
            // So for now we inject a definition of these functions that calls our runtime
            // functions. We do so after optimization to avoid cloning these functions.
            // Float16 conversion routines
#if defined(_CPU_X86_64_) && defined(_OS_DARWIN_)
            // LLVM 16 reverted to soft-float ABI for passing half on x86_64 Darwin
            // https://github.com/llvm/llvm-project/commit/2bcf51c7f82ca7752d1bba390a2e0cb5fdd05ca9
            injectCRTAlias(M, "__gnu_h2f_ieee", "julia_half_to_float",
                    FunctionType::get(Type::getFloatTy(M.getContext()), { Type::getInt16Ty(M.getContext()) }, false));
            injectCRTAlias(M, "__extendhfsf2", "julia_half_to_float",
                    FunctionType::get(Type::getFloatTy(M.getContext()), { Type::getInt16Ty(M.getContext()) }, false));
            injectCRTAlias(M, "__gnu_f2h_ieee", "julia_float_to_half",
                    FunctionType::get(Type::getInt16Ty(M.getContext()), { Type::getFloatTy(M.getContext()) }, false));
            injectCRTAlias(M, "__truncsfhf2", "julia_float_to_half",
                    FunctionType::get(Type::getInt16Ty(M.getContext()), { Type::getFloatTy(M.getContext()) }, false));
            injectCRTAlias(M, "__truncdfhf2", "julia_double_to_half",
                    FunctionType::get(Type::getInt16Ty(M.getContext()), { Type::getDoubleTy(M.getContext()) }, false));
#else
            injectCRTAlias(M, "__gnu_h2f_ieee", "julia__gnu_h2f_ieee",
                    FunctionType::get(Type::getFloatTy(M.getContext()), { Type::getHalfTy(M.getContext()) }, false));
            injectCRTAlias(M, "__extendhfsf2", "julia__gnu_h2f_ieee",
                    FunctionType::get(Type::getFloatTy(M.getContext()), { Type::getHalfTy(M.getContext()) }, false));
            injectCRTAlias(M, "__gnu_f2h_ieee", "julia__gnu_f2h_ieee",
                    FunctionType::get(Type::getHalfTy(M.getContext()), { Type::getFloatTy(M.getContext()) }, false));
            injectCRTAlias(M, "__truncsfhf2", "julia__gnu_f2h_ieee",
                    FunctionType::get(Type::getHalfTy(M.getContext()), { Type::getFloatTy(M.getContext()) }, false));
            injectCRTAlias(M, "__truncdfhf2", "julia__truncdfhf2",
                    FunctionType::get(Type::getHalfTy(M.getContext()), { Type::getDoubleTy(M.getContext()) }, false));
#endif

            // BFloat16 conversion routines
            injectCRTAlias(M, "__truncsfbf2", "julia__truncsfbf2",
                    FunctionType::get(Type::getBFloatTy(M.getContext()), { Type::getFloatTy(M.getContext()) }, false));
            injectCRTAlias(M, "__truncdfbf2", "julia__truncdfbf2",
                    FunctionType::get(Type::getBFloatTy(M.getContext()), { Type::getDoubleTy(M.getContext()) }, false));
        }
        timers.optimize.stopTimer();
    }

    if (opt) {
        timers.opt.startTimer();
        emit_bitcode(M, *TM, out.opt);
        timers.opt.stopTimer();
    }

    if (obj) {
        timers.obj.startTimer();
        TimeTraceScope EmitScope("AOT Emit Object", M.getModuleIdentifier());
        emit_native(M, *TM, out.obj, false);
        timers.obj.stopTimer();
    }

    if (asm_) {
        timers.asm_.startTimer();
        emit_native(M, *TM, out.asm_, true);
        timers.asm_.stopTimer();
    }

    return out;
}

// serialize module to bitcode
static auto serializeModule(const Module &M) {
    assert(!verifyLLVMIR(M) && "Serializing invalid module!");
    SmallVector<char, 0> ClonedModuleBuffer;
    BitcodeWriter BCWriter(ClonedModuleBuffer);
    BCWriter.writeModule(M);
    BCWriter.writeSymtab();
    BCWriter.writeStrtab();
    return ClonedModuleBuffer;
}

// Modules are deserialized lazily by LLVM, to avoid deserializing
// unnecessary functions. We take advantage of this by serializing
// the entire module once, then deleting the bodies of functions
// that are not in this partition. Once unnecessary functions are
// deleted, we then materialize the entire module to make use-lists
// consistent.
static void materializePreserved(Module &M, Partition &partition) {
    DenseSet<GlobalValue *> Preserve;
    for (auto &Name : partition.globals) {
        auto *GV = M.getNamedValue(Name.first());
        assert(GV && !GV->isDeclaration() && !GV->hasLocalLinkage());
        if (!Name.second) {
            // We skip partitioning for internal variables, so this has
            // the same effect as putting it in preserve.
            // This just avoids a hashtable lookup.
            GV->setLinkage(GlobalValue::InternalLinkage);
            assert(GV->hasDefaultVisibility());
        }
        else {
            Preserve.insert(GV);
        }
    }

    for (auto &F : M.functions()) {
        if (F.isDeclaration())
            continue;
        if (F.hasLocalLinkage())
            continue;
        if (Preserve.contains(&F))
            continue;
        if (!canPartition(F)) {
            F.setLinkage(GlobalValue::AvailableExternallyLinkage);
            F.setVisibility(GlobalValue::HiddenVisibility);
            F.setDSOLocal(true);
            continue;
        }
        F.deleteBody();
        F.setLinkage(GlobalValue::ExternalLinkage);
        F.setVisibility(GlobalValue::HiddenVisibility);
        F.setDSOLocal(true);
    }

    for (auto &GV : M.globals()) {
        if (GV.isDeclaration())
            continue;
        if (Preserve.contains(&GV))
            continue;
        if (GV.hasLocalLinkage())
            continue;
        GV.setInitializer(nullptr);
        GV.setLinkage(GlobalValue::ExternalLinkage);
        GV.setVisibility(GlobalValue::HiddenVisibility);
        if (GV.getDLLStorageClass() != GlobalValue::DLLStorageClassTypes::DefaultStorageClass)
            continue; // Don't mess with exported or imported globals
        GV.setDSOLocal(true);
    }

    // Global aliases are a pain to deal with. It is illegal to have an alias to a declaration,
    // so we need to replace them with either a function or a global variable declaration. However,
    // we can't just delete the alias, because that would break the users of the alias. Therefore,
    // we do a dance where we point each global alias to a dummy function or global variable,
    // then materialize the module to access use-lists, then replace all the uses, and finally commit
    // to deleting the old alias.
    SmallVector<std::pair<GlobalAlias *, GlobalValue *>> DeletedAliases;
    for (auto &GA : M.aliases()) {
        assert(!GA.isDeclaration() && "Global aliases can't be declarations!"); // because LLVM says so
        if (Preserve.contains(&GA))
            continue;
        if (GA.hasLocalLinkage())
            continue;
        if (GA.getValueType()->isFunctionTy()) {
            auto F = Function::Create(cast<FunctionType>(GA.getValueType()), GlobalValue::ExternalLinkage, "", &M);
            // This is an extremely sad hack to make sure the global alias never points to an extern function
            auto BB = BasicBlock::Create(M.getContext(), "", F);
            new UnreachableInst(M.getContext(), BB);
            GA.setAliasee(F);
            DeletedAliases.push_back({ &GA, F });
        }
        else {
            auto GV = new GlobalVariable(M, GA.getValueType(), false, GlobalValue::ExternalLinkage, Constant::getNullValue(GA.getValueType()));
            DeletedAliases.push_back({ &GA, GV });
        }
    }

    cantFail(M.materializeAll());

    for (auto &Deleted : DeletedAliases) {
        Deleted.second->takeName(Deleted.first);
        Deleted.first->replaceAllUsesWith(Deleted.second);
        Deleted.first->eraseFromParent();
        // undo our previous sad hack
        if (auto F = dyn_cast<Function>(Deleted.second)) {
            F->deleteBody();
        } else {
            cast<GlobalVariable>(Deleted.second)->setInitializer(nullptr);
        }
    }
}

// Reconstruct jl_fvars, jl_gvars, jl_fvars_idxs, and jl_gvars_idxs from the partition
static void construct_vars(Module &M, Partition &partition, StringRef suffix) {
    SmallVector<std::pair<uint32_t, GlobalValue *>> fvar_pairs;
    fvar_pairs.reserve(partition.fvars.size());
    for (auto &fvar : partition.fvars) {
        auto F = M.getFunction(fvar.first());
        assert(F);
        assert(!F->isDeclaration());
        fvar_pairs.push_back({ fvar.second, F });
    }
    SmallVector<GlobalValue *, 0> fvars;
    SmallVector<uint32_t, 0> fvar_idxs;
    fvars.reserve(fvar_pairs.size());
    fvar_idxs.reserve(fvar_pairs.size());
    std::sort(fvar_pairs.begin(), fvar_pairs.end());
    for (auto &fvar : fvar_pairs) {
        fvars.push_back(fvar.second);
        fvar_idxs.push_back(fvar.first);
    }
    SmallVector<std::pair<uint32_t, GlobalValue *>, 0> gvar_pairs;
    gvar_pairs.reserve(partition.gvars.size());
    for (auto &gvar : partition.gvars) {
        auto GV = M.getNamedGlobal(gvar.first());
        assert(GV);
        assert(!GV->isDeclaration());
        gvar_pairs.push_back({ gvar.second, GV });
    }
    SmallVector<Constant*, 0> gvars;
    SmallVector<uint32_t, 0> gvar_idxs;
    gvars.reserve(gvar_pairs.size());
    gvar_idxs.reserve(gvar_pairs.size());
    std::sort(gvar_pairs.begin(), gvar_pairs.end());
    for (auto &gvar : gvar_pairs) {
        gvars.push_back(gvar.second);
        gvar_idxs.push_back(gvar.first);
    }

    // Now commit the fvars, gvars, and idxs
    auto T_size = M.getDataLayout().getIntPtrType(M.getContext());
    emit_table(M, fvars, "jl_fvars", PointerType::getUnqual(T_size->getContext()));
    emit_offset_table(M, T_size, gvars, "jl_gvar", suffix);
    auto fidxs = ConstantDataArray::get(M.getContext(), fvar_idxs);
    auto fidxs_var = new GlobalVariable(M, fidxs->getType(), true,
                                        GlobalVariable::ExternalLinkage,
                                        fidxs, "jl_fvar_idxs");
    fidxs_var->setVisibility(GlobalValue::HiddenVisibility);
    fidxs_var->setDSOLocal(true);
    auto gidxs = ConstantDataArray::get(M.getContext(), gvar_idxs);
    auto gidxs_var = new GlobalVariable(M, gidxs->getType(), true,
                                        GlobalVariable::ExternalLinkage,
                                        gidxs, "jl_gvar_idxs" + suffix);
    gidxs_var->setVisibility(GlobalValue::HiddenVisibility);
    gidxs_var->setDSOLocal(true);
}

template<typename CB>
static inline void schedule_uv_thread(uv_thread_t *worker, CB &&cb)
{
    auto func = new CB(std::move(cb));
    // Use libuv thread to avoid issues with stack sizes
    uv_thread_create(worker, [] (void *arg) {
        auto func = static_cast<CB*>(arg);
        (*func)();
        delete func;
    }, func);
}

// Entrypoint to optionally-multithreaded image compilation. This handles global coordination of the threading,
// as well as partitioning, serialization, and deserialization. `threads` is the
// partition (shard) count and `workers` the ceiling on concurrency; when
// `jobserver` is non-null the actual thread pool is rationed elastically from
// the shared imaging token budget.
template<typename ModuleReleasedFunc>
static SmallVector<AOTOutputs, 16> add_output(Module &M, TargetMachine &TM, StringRef name, unsigned threads, unsigned workers,
                bool unopt_out, bool opt_out, bool obj_out, bool asm_out,
                JobserverClient *jobserver, ModuleReleasedFunc module_released) {
    SmallVector<AOTOutputs, 16> outputs(threads);
    assert(threads);
    assert(workers && workers <= threads);
    assert(unopt_out || opt_out || obj_out || asm_out);
    // Timers for timing purposes
    TimerGroup timer_group("add_output", ("Time to optimize and emit LLVM module " + name).str());
    SmallVector<ShardTimers, 1> timers(threads);
    for (unsigned i = 0; i < threads; ++i) {
        auto idx = std::to_string(i);
        timers[i].name = "shard_" + idx;
        timers[i].desc = ("Timings for " + name + " module shard " + idx).str();
        timers[i].deserialize.init("deserialize_" + idx, "Deserialize module");
        timers[i].materialize.init("materialize_" + idx, "Materialize declarations");
        timers[i].construct.init("construct_" + idx, "Construct partitioned definitions");
        timers[i].unopt.init("unopt_" + idx, "Emit unoptimized bitcode");
        timers[i].optimize.init("optimize_" + idx, "Optimize shard");
        timers[i].opt.init("opt_" + idx, "Emit optimized bitcode");
        timers[i].obj.init("obj_" + idx, "Emit object file");
        timers[i].asm_.init("asm_" + idx, "Emit assembly file");
    }
    Timer partition_timer("partition", "Partition module", timer_group);
    Timer serialize_timer("serialize", "Serialize module", timer_group);
    Timer output_timer("output", "Add outputs", timer_group);
    bool report_timings = false;
    if (auto env = getenv("JULIA_IMAGE_TIMINGS")) {
        char *endptr;
        unsigned long val = strtoul(env, &endptr, 10);
        if (endptr != env && !*endptr && val <= 1) {
            report_timings = val;
        } else {
            if (StringRef("true").compare_insensitive(env) == 0)
                report_timings = true;
            else if (StringRef("false").compare_insensitive(env) == 0)
                report_timings = false;
            else
                errs() << "WARNING: Invalid value for JULIA_IMAGE_TIMINGS: " << env << "\n";
        }
    }
    if (threads == 1) {
        output_timer.startTimer();
        {
            JL_TIMING(NATIVE_AOT, NATIVE_Opt);
            // convert gvars to the expected offset table format for shard 0
            if (M.getGlobalVariable("jl_gvars")) {
                auto gvars = consume_gv<Constant>(M, "jl_gvars", false);
                Type *T_size = M.getDataLayout().getIntPtrType(M.getContext());
                emit_offset_table(M, T_size, gvars, "jl_gvar", "_0"); // module flag "julia.mv.suffix"
                M.getGlobalVariable("jl_gvar_idxs")->setName("jl_gvar_idxs_0");
            }
            outputs[0] = add_output_impl(M, TM, timers[0], unopt_out, opt_out, obj_out, asm_out);
        }
        output_timer.stopTimer();
        // Don't need M anymore
        module_released(M);

        if (!report_timings) {
            timer_group.clear();
        } else {
            timer_group.print(dbgs(), true);
            for (auto &t : timers) {
                t.print(dbgs(), true);
            }
        }
        return outputs;
    }

    partition_timer.startTimer();
    uint64_t counter = 0;
    // Partitioning requires all globals to have names.
    // We use a prefix to avoid name conflicts with user code.
    for (auto &G : M.global_values()) {
        if (!G.isDeclaration() && !G.hasName()) {
            G.setName("jl_ext_" + Twine(counter++));
        }
    }
    auto partitions = partitionModule(M, threads);
    partition_timer.stopTimer();

    serialize_timer.startTimer();
    auto serialized = serializeModule(M);
    serialize_timer.stopTimer();

    // Don't need M anymore, since we'll only read from serialized from now on
    module_released(M);

    output_timer.startTimer();

    // Compile the partitions with a pool of worker threads pulling from a
    // shared queue. The partition count fixes the shard layout; the pool size
    // only controls how many compile concurrently. Without a jobserver the pool
    // is `workers` threads. With one it is elastic: it starts with the
    // baseline thread plus whatever tokens are free, polls for tokens released
    // by sibling workers while unclaimed partitions remain, and returns each
    // token as soon as its thread runs out of work.
    {
        JL_TIMING(NATIVE_AOT, NATIVE_Opt);
        std::atomic<unsigned> next_partition{0};
        std::mutex pool_mutex; // guards held_tokens and live_threads
        unsigned held_tokens = 0;
        unsigned live_threads = 0;
        std::vector<uv_thread_t> worker_threads(threads);
        unsigned spawned = 0;
        auto spawn_worker = [&]() {
            unsigned t = spawned++;
            schedule_uv_thread(&worker_threads[t], [&, t]() {
                // Initialize time trace profiler for this thread if enabled
                if (jl_is_timing_trace)
                    timeTraceProfilerInitialize(jl_timing_trace_granularity, ("aot_thread_" + std::to_string(t)).c_str());
#ifdef USE_TRACY
                std::string tracy_thread_name = "AOT thread " + std::to_string(t);
                TracyCSetThreadName(tracy_thread_name.c_str());
#endif
                while (true) {
                    unsigned i = next_partition.fetch_add(1, std::memory_order_relaxed);
                    if (i >= threads)
                        break;
                    LLVMContext ctx;
                    ctx.setDiscardValueNames(true);
                    // Lazily deserialize the entire module
                    timers[i].deserialize.startTimer();
                    auto EM = getLazyBitcodeModule(MemoryBufferRef(StringRef(serialized.data(), serialized.size()), "Optimized"), ctx);
                    // Make sure this also fails with only julia, but not LLVM assertions enabled,
                    // otherwise, the first error we hit is the LLVM module verification failure,
                    // which will look very confusing, because the module was partially deserialized.
                    bool deser_succeeded = (bool)EM;
                    auto M = cantFail(std::move(EM), "Error loading module");
                    assert(deser_succeeded); (void)deser_succeeded;
                    timers[i].deserialize.stopTimer();

                    timers[i].materialize.startTimer();
                    materializePreserved(*M, partitions[i]);
                    timers[i].materialize.stopTimer();

                    timers[i].construct.startTimer();
                    std::string suffix = "_" + std::to_string(i);
                    construct_vars(*M, partitions[i], suffix);
                    M->setModuleFlag(Module::Error, "julia.mv.suffix", MDString::get(M->getContext(), suffix));
                    // The DICompileUnit file is not used for anything, but ld64 requires it be a unique string per object file
                    // or it may skip emitting debug info for that file. Here set it to ./julia#N
                    DIFile *topfile = DIFile::get(M->getContext(), "julia#" + std::to_string(i), ".");
                    if (M->getNamedMetadata("llvm.dbg.cu"))
                        for (auto CU: M->getNamedMetadata("llvm.dbg.cu")->operands())
                            CU->replaceOperandWith(0, topfile);
                    timers[i].construct.stopTimer();

                    outputs[i] = add_output_impl(*M, TM, timers[i], unopt_out, opt_out, obj_out, asm_out);
                }
                // Merge this thread's time trace into the main thread
                if (jl_is_timing_trace)
                    timeTraceProfilerFinishThread();
                if (jobserver) {
                    // Out of work: return the surplus token so siblings can scale
                    // into it. The baseline token covers one thread, so keep
                    // held_tokens at live_threads - 1.
                    std::lock_guard<std::mutex> lock(pool_mutex);
                    live_threads--;
                    if (held_tokens > 0 && held_tokens >= live_threads) {
                        held_tokens--;
                        jobserver->release(1);
                    }
                }
            });
        };

        unsigned initial_pool = workers;
        if (jobserver) {
            // The orchestrator already holds this worker's baseline token (its
            // main thread only sleeps/polls below); ration the rest from the pool.
            held_tokens = jobserver->acquire(workers - 1);
            initial_pool = 1 + held_tokens;
        }
        live_threads = initial_pool;
        while (spawned < initial_pool)
            spawn_worker();

        // Elastic scale-up: while unclaimed partitions remain, grow the pool
        // as sibling precompile workers return tokens to the budget.
        while (jobserver && spawned < workers) {
            unsigned claimed = next_partition.load(std::memory_order_relaxed);
            if (claimed >= threads)
                break;
            unsigned want = std::min(threads - claimed, workers - spawned);
            unsigned got = jobserver->acquire(want);
            if (got) {
                {
                    std::lock_guard<std::mutex> lock(pool_mutex);
                    held_tokens += got;
                    live_threads += got;
                }
                for (unsigned k = 0; k < got; k++)
                    spawn_worker();
            }
            else {
                uv_sleep(100);
            }
        }

        // Wait for all of the worker threads to finish
        for (unsigned t = 0; t < spawned; t++)
            uv_thread_join(&worker_threads[t]);
        assert(held_tokens == 0 && "precompile jobserver tokens leaked");
    }

    output_timer.stopTimer();

    if (!report_timings) {
        timer_group.clear();
    } else {
        timer_group.print(dbgs(), true);
        for (auto &t : timers) {
            t.print(dbgs(), true);
        }
        dbgs() << "Partition weights: [";
        bool comma = false;
        for (auto &p : partitions) {
            if (comma)
                dbgs() << ", ";
            else
                comma = true;
            dbgs() << p.weight;
        }
        dbgs() << "]\n";
    }
    return outputs;
}

constexpr size_t jl_image_max_shard_weight = 250000;
constexpr size_t jl_image_min_shard_weight = 10000;

static unsigned get_env_threads(const char *name)
{
    const char *env = getenv(name);
    if (!env)
        return 0;
    char *endptr;
    unsigned long requested = strtoul(env, &endptr, 10);
    if (*endptr || !requested) {
        jl_safe_printf("WARNING: invalid value '%s' for %s\n", env, name);
        return 0;
    }
    return requested;
}

static unsigned compute_image_thread_count() {
    if (jl_is_timing_passes) // LLVM isn't thread safe when timing the passes https://github.com/llvm/llvm-project/issues/44417
        return 1;

#ifdef _P32
    // We need to be very careful about using too much memory on 32 bit.
    return 1;
#endif

    // environment variable override.
    // this controls how many threads we request from the jobserver (if it is enabled)
    // but the question of whether to enable it or not is decided upstream
    if (unsigned requested = get_env_threads("JULIA_IMAGE_THREADS")) {
        LLVM_DEBUG(dbgs() << "Overriding threads to " << requested << " due to JULIA_IMAGE_THREADS\n");
        return requested;
    }

    unsigned threads = jl_effective_threads();

    // more defaults
    unsigned requested = get_env_threads("JULIA_CPU_THREADS");
    if (requested && requested < threads) {
        LLVM_DEBUG(dbgs() << "Overriding threads to " << requested << " due to JULIA_CPU_THREADS\n");
        threads = requested;
    }

    return threads;
}

static unsigned compute_image_shard_count(const ModuleInfo &info, unsigned workers)
{
    size_t max_shards = std::max<size_t>(info.weight / jl_image_min_shard_weight, 1);
    size_t shards = std::max<size_t>(divideCeil(info.weight, jl_image_max_shard_weight),
                                     std::min<size_t>(workers, max_shards));
    if (shards > workers)
        shards = std::min<size_t>(alignTo(shards, workers), std::max(shards, max_shards));
    return shards;
}

jl_emission_params_t default_emission_params = { 1 };

static void jl_dump_native_locked(jl_native_code_desc_t *data, const char *bc_fname,
                           const char *unopt_bc_fname, const char *obj_fname,
                           const char *asm_fname, ios_t *z, uint32_t checksum,
                           const char *unpack_func, jl_emission_params_t *params,
                           Module &dataM)
{
    // `data` is deleted when the text outputs finish compiling, well before
    // the metadata module is built, so take what the coverage table needs now.
    auto coverage_entries = std::move(data->jl_coverage_entries);
    // The same for the parts of a store: their objects, and the names and the
    // indexes of their functions and slots, for the shard of the parts.
    auto part_objects = std::move(data->part_objects);
    std::vector<std::pair<std::string, uint32_t>> part_fvars, part_gvars;
    for (size_t i = data->part_fvars_begin; i < data->part_fvars_end; i++)
        part_fvars.emplace_back(data->jl_sysimg_fvars[i]->getName().str(), i);
    for (size_t i = data->part_gvars_begin; i < data->part_gvars_end; i++)
        part_gvars.emplace_back(data->jl_sysimg_gvars[i]->getName().str(), i);
    bool has_parts = !part_objects.empty() || !part_fvars.empty();

    // We don't want to use MCJIT's target machine because
    // it uses the large code model and we may potentially
    // want less optimizations there.
    // make sure to emit the native object format, even if FORCE_ELF was set in codegen
    Triple TheTriple = data->out->TargetTriple;
    if (TheTriple.isOSWindows()) {
        TheTriple.setObjectFormat(Triple::COFF);
    } else if (TheTriple.isOSDarwin()) {
        TheTriple.setObjectFormat(Triple::MachO);
        SmallString<16> Str;
        Str += "macosx";
        if (TheTriple.isAArch64())
            Str += "11.0.0"; // Update this if MACOSX_VERSION_MIN changes
        else
            Str += "10.14.0";
        TheTriple.setOSName(Str);
    }
    std::optional<Reloc::Model> RelocModel;
    if (TheTriple.isOSLinux() || TheTriple.isOSFreeBSD() || TheTriple.isOSOpenBSD()) {
        RelocModel = Reloc::PIC_;
    }

    CodeModel::Model CMModel = CodeModel::Small;
    if (TheTriple.isPPC() || TheTriple.isRISCV() ||
        (TheTriple.isX86() && TheTriple.isArch64Bit() && TheTriple.isOSLinux())) {
        // On PPC the small model is limited to 16bit offsets. For very large images the small code model
        CMModel = CodeModel::Medium; //  isn't good enough on x86 so use Medium, it has no cost because only the image goes in .ldata
    }
    std::string Features = jl_ExecutionEngine->getTargetFeatureString().str();
    if (TheTriple.isRISCV())
        Features += ",+relax"; // provide the optimization for functions which themselves don't have a target string
    std::unique_ptr<TargetMachine> SourceTM(
        jl_ExecutionEngine->getTarget().createTargetMachine(
            TheTriple,
            jl_ExecutionEngine->getTargetCPU(),
            Features,
            jl_ExecutionEngine->getTargetOptions(),
            RelocModel,
            CMModel,
            CodeGenOptLevelFor(jl_options.opt_level) // respect the command-line -O flag
            ));
    fixupTM(*SourceTM);
    auto DL = jl_create_datalayout(*SourceTM);
    std::string StackProtectorGuard = dataM.getStackProtectorGuard().str();
    unsigned OverrideStackAlignment = dataM.getOverrideStackAlignment();

    auto compile = [&](Module &M, StringRef name, unsigned shards, unsigned workers, JobserverClient *jobserver, auto module_released) {
        return add_output(M, *SourceTM, name, shards, workers, !!unopt_bc_fname, !!bc_fname, !!obj_fname, !!asm_fname, jobserver, module_released);
    };

    SmallVector<AOTOutputs, 16> sysimg_outputs;
    SmallVector<AOTOutputs, 16> data_outputs;
    SmallVector<AOTOutputs, 16> metadata_outputs;
    {
        JL_TIMING(NATIVE_AOT, NATIVE_Sysimg);
        LLVMContext Context;
        Context.setDiscardValueNames(true);
        Module sysimgM("sysimg", Context);
        sysimgM.setTargetTriple(TheTriple);
        sysimgM.setDataLayout(DL);
        sysimgM.setStackProtectorGuard(StackProtectorGuard);
        sysimgM.setOverrideStackAlignment(OverrideStackAlignment);

        if (z) {
            ArrayRef<char> sysimg_data{z->buf, (size_t)z->size};
            Constant *data = ConstantDataArray::get(Context, sysimg_data);
            auto sysdata = new GlobalVariable(sysimgM, data->getType(), false,
                                              GlobalVariable::ExternalLinkage,
                                              data, "jl_system_image_data");
            sysdata->setAlignment(Align(jl_page_size));
            sysdata->setCodeModel(CodeModel::Large);
            addComdat(sysdata, TheTriple);
            Constant *len = ConstantInt::get(sysimgM.getDataLayout().getIntPtrType(Context), sysimg_data.size());
            addComdat(new GlobalVariable(sysimgM, len->getType(), true,
                                         GlobalVariable::ExternalLinkage,
                                         len, "jl_system_image_size"), TheTriple);

            // Free z here, since we've copied out everything into data
            // Results in serious memory savings
            ios_close(z);
            free(z);
        }

        Constant *checksum_val = ConstantInt::get(Type::getInt32Ty(Context), checksum);
        addComdat(new GlobalVariable(sysimgM, checksum_val->getType(), true,
                                     GlobalVariable::ExternalLinkage,
                                     checksum_val, "jl_system_image_checksum"), TheTriple);

        auto unpack =
            new GlobalVariable(sysimgM, DL.getIntPtrType(Context), true,
                               GlobalVariable::ExternalLinkage, nullptr, unpack_func);
        addComdat(new GlobalVariable(sysimgM, PointerType::getUnqual(Context), true,
                                     GlobalVariable::ExternalLinkage, unpack,
                                     "jl_image_unpack"),
                  TheTriple);

        // Note that we don't set z to null, this allows the check in WRITE_ARCHIVE
        // to function as expected
        // no need to free the module/context, destructor handles that
        sysimg_outputs = compile(sysimgM, "sysimg", 1, 1, nullptr, [](Module &) {});
    }

    const bool imaging_mode = true;
    unsigned shards = 1;
    unsigned workers = 1;
    unsigned nfvars = 0;
    unsigned ngvars = 0;

    // Coordinate AOT codegen parallelism with other precompile workers via the
    // precompile jobserver (JuliaLang/julia#58591). When active, add_output sizes
    // its thread pool elastically against the shared token budget.
    JobserverClient jobserver;
    jobserver.open();
    JobserverClient *text_jobserver = nullptr;

    // Reset the target triple to make sure it matches the new target machine

    {
        JL_TIMING(NATIVE_AOT, NATIVE_Setup);
        dataM.setDataLayout(DL);
        dataM.setPICLevel(PICLevel::BigPIC);
        auto &Context = data->out->get_context();

        Type *T_psize = PointerType::getUnqual(Context);

        // This should really be in jl_create_native, but we haven't
        // yet set the target triple binary format correctly at that
        // point. This should be resolved when we start JITting for
        // COFF when we switch over to JITLink.
        for (auto &GA : dataM.aliases()) {
            // Global aliases are only used for ccallable things, so we should
            // mark them as dllexport
            addComdat(&GA, TheTriple);
        }

        // add metadata information
        if (imaging_mode) {
            multiversioning_preannotate(dataM);
            {
                DenseSet<GlobalValue *> fvars(data->jl_sysimg_fvars.begin(), data->jl_sysimg_fvars.end());
                for (auto &F : dataM) {
                    if (F.hasFnAttribute("julia.mv.reloc") || F.hasFnAttribute("julia.mv.fvar")) {
                        if (fvars.insert(&F).second) {
                            data->jl_sysimg_fvars.push_back(&F);
                        }
                    }
                }
            }

            ModuleInfo module_info = compute_module_info(dataM);
            LLVM_DEBUG(dbgs()
                << "Dumping module with stats:\n"
                << "    globals: " << module_info.globals << "\n"
                << "    functions: " << module_info.funcs << "\n"
                << "    basic blocks: " << module_info.bbs << "\n"
                << "    instructions: " << module_info.insts << "\n"
                << "    clones: " << module_info.clones << "\n"
                << "    weight: " << module_info.weight << "\n"
            );
            workers = compute_image_thread_count();
            shards = compute_image_shard_count(module_info, workers);
            workers = std::min(workers, shards);
            if (jobserver.active() && workers > 1) {
                // `shards` is the partition count and `workers` the concurrency
                // ceiling; add_output rations the actual pool size from the
                // shared token budget, growing it as sibling workers finish.
                text_jobserver = &jobserver;
            }
            LLVM_DEBUG(dbgs() << "Using " << shards << " shards and up to " << workers << " threads to emit aot image\n");
            nfvars = data->jl_sysimg_fvars.size();
            ngvars = data->jl_sysimg_gvars.size();
            // The shards that this image compiles take all slots and functions
            // but those of the parts of a store, which have a shard of their own.
            SmallVector<GlobalValue *, 0> text_gvars, text_fvars;
            SmallVector<uint32_t, 0> text_gidxs, text_fidxs;
            for (size_t i = 0; i < data->jl_sysimg_gvars.size(); i++) {
                if (i < data->part_gvars_begin || i >= data->part_gvars_end) {
                    text_gvars.push_back(data->jl_sysimg_gvars[i]);
                    text_gidxs.push_back(i);
                }
            }
            for (size_t i = 0; i < data->jl_sysimg_fvars.size(); i++) {
                if (i < data->part_fvars_begin || i >= data->part_fvars_end) {
                    text_fvars.push_back(data->jl_sysimg_fvars[i]);
                    text_fidxs.push_back(i);
                }
            }
            emit_table(dataM, text_gvars, "jl_gvars", T_psize);
            emit_table(dataM, text_fvars, "jl_fvars", T_psize);
            SmallVector<uint32_t, 0> idxs = text_gidxs;
            auto gidxs = ConstantDataArray::get(Context, idxs);
            auto gidxs_var = new GlobalVariable(dataM, gidxs->getType(), true,
                                                GlobalVariable::ExternalLinkage,
                                                gidxs, "jl_gvar_idxs");
            gidxs_var->setVisibility(GlobalValue::HiddenVisibility);
            gidxs_var->setDSOLocal(true);
            idxs = text_fidxs;
            auto fidxs = ConstantDataArray::get(Context, idxs);
            auto fidxs_var = new GlobalVariable(dataM, fidxs->getType(), true,
                                                GlobalVariable::ExternalLinkage,
                                                fidxs, "jl_fvar_idxs");
            fidxs_var->setVisibility(GlobalValue::HiddenVisibility);
            fidxs_var->setDSOLocal(true);
            dataM.addModuleFlag(Module::Error, "julia.mv.suffix", MDString::get(Context, "_0"));

            // let the compiler know we are going to internalize a copy of this,
            // if it has a current usage with ExternalLinkage
            auto jl_small_typeof_copy = dataM.getGlobalVariable("jl_small_typeof");
            if (jl_small_typeof_copy) {
                jl_small_typeof_copy->setVisibility(GlobalValue::HiddenVisibility);
                jl_small_typeof_copy->setDSOLocal(true);
                jl_small_typeof_copy->setDLLStorageClass(GlobalValue::DLLStorageClassTypes::DefaultStorageClass);
            }
        }

    };

    {
        data_outputs = compile(dataM, "text", shards, workers, text_jobserver, [data](Module &) {
            // Delete data when add_output thinks it's done with it
            // Saves memory for use when multithreading
            delete data;
        });
    }

    // All imaging tokens were returned to the shared pool as add_output's
    // worker threads ran out of work.
    jobserver.close();

    if (params->emit_metadata) {
        JL_TIMING(NATIVE_AOT, NATIVE_Metadata);
        LLVMContext Context;
        Context.setDiscardValueNames(true);
        Module metadataM("metadata", Context);
        metadataM.setTargetTriple(TheTriple);
        metadataM.setDataLayout(DL);
        metadataM.setStackProtectorGuard(StackProtectorGuard);
        metadataM.setOverrideStackAlignment(OverrideStackAlignment);

        // reflect the address of the jl_RTLD_DEFAULT_handle variable
        // back to the caller, so that we can check for consistency issues
        GlobalValue *jlRTLD_DEFAULT_var = jl_emit_RTLD_DEFAULT_var(&metadataM);

        Type *T_size = DL.getIntPtrType(Context);
        Type *T_psize = PointerType::getUnqual(T_size->getContext());
        Type *T_ptr = PointerType::get(Context, 0);

        auto FT = FunctionType::get(PointerType::getUnqual(Context), {}, false);
        auto F = Function::Create(FT, Function::ExternalLinkage, "get_jl_RTLD_DEFAULT_handle_addr", metadataM);
        llvm::IRBuilder<> builder(BasicBlock::Create(Context, "top", F));
        builder.CreateRet(jlRTLD_DEFAULT_var);
        F->setLinkage(GlobalValue::ExternalLinkage);
        if (TheTriple.isOSBinFormatCOFF())
            F->setDLLStorageClass(GlobalValue::DLLStorageClassTypes::DLLExportStorageClass);

        if (TheTriple.isOSWindows()) {
            // Windows expect that the function `_DllMainStartup` is present in an dll.
            // Normal compilers use something like Zig's crtdll.c instead we provide a
            // a stub implementation.
            auto T_pvoid = PointerType::getUnqual(Context);
            auto T_int32 = Type::getInt32Ty(Context);
            auto FT = FunctionType::get(T_int32, {T_pvoid, T_int32, T_pvoid}, false);
            auto F = Function::Create(FT, Function::ExternalLinkage, "_DllMainCRTStartup", metadataM);
            F->setCallingConv(CallingConv::X86_StdCall);

            llvm::IRBuilder<> builder(BasicBlock::Create(Context, "top", F));
            builder.CreateRet(ConstantInt::get(T_int32, 1));
        }
        if (imaging_mode) {
            jl_clone_targets_t targets = jl_get_llvm_clone_targets(jl_options.cpu_target);
            ArrayRef<uint8_t> data(targets.data, targets.data_size);
            auto value = ConstantDataArray::get(Context, data);
            auto target_ids = new GlobalVariable(metadataM, value->getType(), true,
                                        GlobalVariable::InternalLinkage,
                                        value, "jl_dispatch_target_ids");
            if (has_parts)
                emit_parts_shard(metadataM, T_size, shards, part_fvars, part_gvars);
            unsigned all_shards = shards + (has_parts ? 1 : 0);
            auto shard_table = emit_shard_table(metadataM, T_size, T_psize, all_shards);
            auto ptls = emit_ptls_table(metadataM, T_size, T_ptr);
            auto header = emit_image_header(metadataM, all_shards, nfvars, ngvars);
            auto AT = ArrayType::get(T_size, sizeof(jl_small_typeof) / sizeof(void*));
            auto jl_small_typeof_copy = new GlobalVariable(metadataM, AT, false,
                                                        GlobalVariable::ExternalLinkage,
                                                        Constant::getNullValue(AT),
                                                        "jl_small_typeof");
            jl_small_typeof_copy->setVisibility(GlobalValue::HiddenVisibility);
            jl_small_typeof_copy->setDSOLocal(true);

            // Create CPU target string constant.
            // Don't store "sysimage" keyword — store the actual resolved target string.
            char *expanded = jl_expand_sysimage_keyword(jl_options.cpu_target);
            std::string cpu_target_str(expanded);
            free(expanded);
            auto cpu_target_data = ConstantDataArray::getString(Context, cpu_target_str, true);
            auto cpu_target_global = new GlobalVariable(metadataM, cpu_target_data->getType(), true,
                                                       GlobalVariable::InternalLinkage,
                                                       cpu_target_data, "jl_cpu_target_string");

            // Emit the coverage counter table (jl_image_coverage_t); the loader
            // registers the counters so image code contributes to reports. An
            // empty table still marks the image as instrumented.
            if (jl_image_coverage_config() != 0) {
                Type *T_i32 = Type::getInt32Ty(Context);
                Type *T_i64 = Type::getInt64Ty(Context);
                StructType *ET = StructType::get(Context, {T_ptr, T_ptr, T_i32, T_i32});
                StringMap<GlobalVariable*> files;
                SmallVector<Constant*, 0> entries;
                entries.reserve(coverage_entries.size());
                for (auto &[file, line, flags, sym] : coverage_entries) {
                    GlobalVariable *&fgv = files[file];
                    if (!fgv) {
                        auto fdata = ConstantDataArray::getString(Context, file, true);
                        fgv = new GlobalVariable(metadataM, fdata->getType(), true,
                                                 GlobalVariable::PrivateLinkage, fdata,
                                                 "jl_coverage_file");
                    }
                    auto counter = cast<GlobalVariable>(metadataM.getOrInsertGlobal(sym, T_i64));
                    counter->setVisibility(GlobalValue::HiddenVisibility);
                    counter->setDSOLocal(true);
                    entries.push_back(ConstantStruct::get(ET, {(Constant*)fgv, (Constant*)counter,
                        ConstantInt::get(T_i32, line), ConstantInt::get(T_i32, flags)}));
                }
                auto entries_arr = ConstantArray::get(ArrayType::get(ET, entries.size()), entries);
                auto entries_gv = new GlobalVariable(metadataM, entries_arr->getType(), true,
                                                     GlobalVariable::PrivateLinkage, entries_arr,
                                                     "jl_coverage_entries");
                StructType *CT = StructType::get(Context, {T_i32, T_i64, T_ptr});
                auto cov = new GlobalVariable(metadataM, CT, true,
                                              GlobalVariable::ExternalLinkage,
                                              ConstantStruct::get(CT, {
                                                  ConstantInt::get(T_i32, jl_image_coverage_config()),
                                                  ConstantInt::get(T_i64, entries.size()),
                                                  (Constant*)entries_gv}),
                                              "jl_image_coverage");
                addComdat(cov, TheTriple);
            }

            AT = ArrayType::get(T_psize, 6);
            auto pointers = new GlobalVariable(metadataM, AT, false,
                                            GlobalVariable::ExternalLinkage,
                                            ConstantArray::get(AT, {
                                                    ConstantExpr::getBitCast(header, T_psize),
                                                    ConstantExpr::getBitCast(shard_table, T_psize),
                                                    ConstantExpr::getBitCast(ptls, T_psize),
                                                    ConstantExpr::getBitCast(jl_small_typeof_copy, T_psize),
                                                    ConstantExpr::getBitCast(target_ids, T_psize),
                                                    ConstantExpr::getBitCast(cpu_target_global, T_psize)
                                            }),
                                            "jl_image_pointers");
            addComdat(pointers, TheTriple);
            jl_free_clone_targets(&targets);
        }

        // no need to free module/context, destructor handles that
        metadata_outputs = compile(metadataM, "data", 1, 1, nullptr, [](Module &) {});
    }

    {
        JL_TIMING(NATIVE_AOT, NATIVE_Write);

        object::Archive::Kind Kind = getDefaultForHost(TheTriple);
#define WRITE_ARCHIVE(fname, field, prefix, suffix) \
    if (fname) {\
        SmallVector<NewArchiveMember, 0> archive; \
        SmallVector<std::string, 16> filenames; \
        SmallVector<StringRef, 16> buffers; \
        for (size_t i = 0; i < shards; i++) { \
            filenames.push_back((StringRef("text") + prefix + "#" + Twine(i) + suffix).str()); \
            buffers.push_back(StringRef(data_outputs[i].field.data(), data_outputs[i].field.size())); \
        } \
        filenames.push_back("metadata" prefix suffix); \
        buffers.push_back(StringRef(metadata_outputs[0].field.data(), metadata_outputs[0].field.size())); \
        filenames.push_back("sysimg" prefix suffix); \
        buffers.push_back(StringRef(sysimg_outputs[0].field.data(), sysimg_outputs[0].field.size())); \
        if (StringRef(suffix) == ".o") { \
            for (auto &part : part_objects) { \
                filenames.push_back(part.first); \
                buffers.push_back(StringRef(part.second)); \
            } \
        } \
        for (size_t i = 0; i < filenames.size(); i++) { \
            archive.push_back(NewArchiveMember(MemoryBufferRef(buffers[i], filenames[i]))); \
        } \
        handleAllErrors(writeArchive(fname, archive, SymtabWritingMode::NormalSymtab, Kind, true, false), reportWriterError); \
    }

        WRITE_ARCHIVE(unopt_bc_fname, unopt, "_unopt", ".bc");
        WRITE_ARCHIVE(bc_fname, opt, "_opt", ".bc");
        WRITE_ARCHIVE(obj_fname, obj, "", ".o");
        WRITE_ARCHIVE(asm_fname, asm_, "", ".s");
#undef WRITE_ARCHIVE
    }
}

// takes the running content that has collected in the shadow module and dump it to disk
// this builds the object file portion of the sysimage files for fast startup
extern "C" JL_DLLEXPORT_CODEGEN void
jl_dump_native_impl(void *native_code, const char *bc_fname, const char *unopt_bc_fname,
                    const char *obj_fname, const char *asm_fname, ios_t *z,
                    uint32_t checksum, const char *unpack_func,
                    jl_emission_params_t *params)
{
    JL_TIMING(NATIVE_AOT, NATIVE_Dump);
    jl_native_code_desc_t *data = (jl_native_code_desc_t*)native_code;
    if (!bc_fname && !unopt_bc_fname && !obj_fname && !asm_fname) {
        LLVM_DEBUG(dbgs() << "No output requested, skipping native code dump?\n");
        delete data;
        return;
    }

    if (!params) {
        params = &default_emission_params;
    }

    // We can destroy the LLVM context earlier if we own ThreadSafeModule and
    // ThreadSafeContext.
    if (data->TSM_ref == &data->TSM) {
        jl_dump_native_locked(data, bc_fname, unopt_bc_fname, obj_fname, asm_fname, z,
                              checksum, unpack_func, params, *data->TSM.getModuleUnlocked());
    }
    else {
        data->TSM_ref->withModuleDo([&](Module &dataM) {
            jl_dump_native_locked(data, bc_fname, unopt_bc_fname, obj_fname, asm_fname, z,
                                  checksum, unpack_func, params, dataM);
        });
    }
}

// Compile the inferred code instances of `codeinfos` (in the form that
// `jl_emit_native` takes) into one relocatable object, which another process
// installs later with `jl_install_objects`. The code has the form of an image:
// it reaches each Julia object through a slot, a global `<prefix>#slot#<i>`
// that the installer fills, and the state of the thread through the slots of
// the runtime.
//
// `parts` is `nothing` for an object of its own, with the prefix `jl_object`.
// Else it is `svec(prefix, cis, names)`, the names of the functions of the
// code instances of a store of parts: a function of a code instance of `cis`
// gets its name of `names` (its invoke wrapper the name with `.jfptr`), and a
// call to one that this object does not compile stays a declaration of that
// name, which the link of the parts resolves. Each other definition becomes
// internal, so that the objects of the parts do not clash.
//
// Answer `svec(object, slots, functions, calls)`: the bytes of the object, the
// Julia object of each slot by its index, for each code instance a
// `svec(ci, invoke_api, invoke, specptr)` with the names of its symbols, and
// for each call to another part a `svec(ci, invoke_api, name)`.
extern "C" JL_DLLEXPORT_CODEGEN
jl_value_t *jl_emit_object_impl(jl_array_t *codeinfos, jl_value_t *parts)
{
    jl_array_t *ci_order = NULL, *object = NULL, *slots = NULL, *functions = NULL, *calls = NULL;
    jl_value_t *result = NULL;
    JL_GC_PUSH6(&ci_order, &object, &slots, &functions, &calls, &result);
    std::string prefix = "jl_object";
    DenseMap<jl_code_instance_t *, std::string> part_names;
    bool named = jl_is_svec(parts);
    if (named) {
        prefix = jl_string_data(jl_svecref(parts, 0));
        jl_array_t *cis = (jl_array_t *)jl_svecref(parts, 1);
        jl_array_t *names = (jl_array_t *)jl_svecref(parts, 2);
        for (size_t i = 0; i < jl_array_nrows(cis); i++)
            part_names[(jl_code_instance_t *)jl_array_ptr_ref(cis, i)] = jl_string_data(jl_array_ptr_ref(names, i));
    }
    ci_order = jl_alloc_vec_any(0);
    auto data = emit_native_code(codeinfos, ci_order, NULL, NULL, 0, named ? &part_names : nullptr);
    size_t nslots = data->jl_sysimg_gvars.size();
    assert(nslots == data->jl_value_to_llvm.size() && "a call through the PLT of an image needs external linkage");
    SmallVector<char, 0> obj;
    std::vector<std::tuple<jl_code_instance_t *, int32_t, std::string, std::string>> funcs;
    data->TSM_ref->withModuleDo([&](Module &M) {
        SmallPtrSet<GlobalValue *, 16> keep;
        for (size_t i = 0; i < nslots; i++) {
            auto gv = cast<GlobalVariable>(data->jl_sysimg_gvars[i]);
            gv->setName(prefix + "#slot#" + Twine(i));
            gv->setLinkage(GlobalValue::ExternalLinkage);
            gv->setVisibility(named ? GlobalValue::ProtectedVisibility : GlobalValue::DefaultVisibility);
            keep.insert(gv);
        }
        // The state of the thread comes from the slots of the runtime, which it
        // gives the JIT (`add_shared_named_global` in codegen.cpp).
        Type *T_ptr = PointerType::getUnqual(M.getContext());
        Type *T_size = M.getDataLayout().getIntPtrType(M.getContext());
        for (auto &slot : {std::make_pair("jl_pgcstack_func_slot", T_ptr),
                           std::make_pair("jl_pgcstack_key_slot", T_size),
                           std::make_pair("jl_image_tls_offset", T_size)}) {
            if (!M.getNamedGlobal(slot.first))
                new GlobalVariable(M, slot.second, false, GlobalValue::ExternalLinkage, nullptr, slot.first);
        }
        for (auto &entry : data->jl_fvar_map) {
            jl_code_instance_t *ci = entry.first;
            int32_t invoke_id = std::get<0>(entry.second), specptr_id = std::get<1>(entry.second);
            int32_t api = invoke_id > 0 ? JL_INVOKE_SPECSIG : -invoke_id;
            Function *invoke = invoke_id > 0 ? cast<Function>(data->jl_sysimg_fvars[invoke_id - 1]) : nullptr;
            Function *specptr = specptr_id > 0 ? cast<Function>(data->jl_sysimg_fvars[specptr_id - 1]) : nullptr;
            auto part = part_names.find(ci);
            for (auto f : {invoke, specptr}) {
                if (f == nullptr)
                    continue;
                if (part != part_names.end())
                    f->setName(f == specptr ? part->second : part->second + ".jfptr");
                f->setLinkage(GlobalValue::ExternalLinkage);
                // Protected: the JIT finds the symbol, and a link into an image
                // binds each call to it directly, with no PLT.
                f->setVisibility(named ? GlobalValue::ProtectedVisibility : GlobalValue::DefaultVisibility);
                keep.insert(f);
            }
            funcs.emplace_back(ci, api, invoke ? invoke->getName().str() : "", specptr ? specptr->getName().str() : "");
        }
        if (named) {
            for (auto &gv : M.global_values()) {
                if (!gv.isDeclaration() && !keep.contains(&gv) && !gv.hasLocalLinkage())
                    gv.setLinkage(GlobalValue::InternalLinkage);
            }
        }
        // The target machine of the image writer, with the small code model:
        // the JIT links the object, and no image data goes with it.
        Triple TheTriple = data->out->TargetTriple;
        std::optional<Reloc::Model> RelocModel;
        if (TheTriple.isOSLinux() || TheTriple.isOSFreeBSD() || TheTriple.isOSOpenBSD())
            RelocModel = Reloc::PIC_;
        std::unique_ptr<TargetMachine> TM(
            jl_ExecutionEngine->getTarget().createTargetMachine(
                TheTriple,
                jl_ExecutionEngine->getTargetCPU(),
                jl_ExecutionEngine->getTargetFeatureString(),
                jl_ExecutionEngine->getTargetOptions(),
                RelocModel,
                CodeModel::Small,
                CodeGenOptLevelFor(jl_options.opt_level)));
        fixupTM(*TM);
        ShardTimers timers;
        AOTOutputs out = add_output_impl(M, *TM, timers, false, false, true, false);
        obj = std::move(out.obj);
    });
    object = jl_alloc_array_1d(jl_array_uint8_type, obj.size());
    memcpy(jl_array_data(object, char), obj.data(), obj.size());
    slots = jl_alloc_vec_any(nslots);
    for (size_t i = 0; i < nslots; i++)
        jl_array_ptr_set(slots, i, (jl_value_t *)data->jl_value_to_llvm[i]);
    functions = jl_alloc_vec_any(funcs.size());
    for (size_t k = 0; k < funcs.size(); k++) {
        jl_svec_t *entry = jl_alloc_svec(4);
        jl_array_ptr_set(functions, k, (jl_value_t *)entry);
        jl_svecset(entry, 0, (jl_value_t *)std::get<0>(funcs[k]));
        jl_svecset(entry, 1, jl_box_int32(std::get<1>(funcs[k])));
        jl_svecset(entry, 2, jl_cstr_to_string(std::get<2>(funcs[k]).c_str()));
        jl_svecset(entry, 3, jl_cstr_to_string(std::get<3>(funcs[k]).c_str()));
    }
    auto &part_calls = data->out->part_calls;
    calls = jl_alloc_vec_any(part_calls.size());
    for (size_t k = 0; k < part_calls.size(); k++) {
        jl_svec_t *entry = jl_alloc_svec(3);
        jl_array_ptr_set(calls, k, (jl_value_t *)entry);
        jl_svecset(entry, 0, (jl_value_t *)std::get<0>(part_calls[k]));
        jl_svecset(entry, 1, jl_box_int32(std::get<1>(part_calls[k])));
        jl_svecset(entry, 2, jl_cstr_to_string(std::get<2>(part_calls[k]).c_str()));
    }
    delete data;
    result = (jl_value_t *)jl_svec(4, object, slots, functions, calls);
    JL_GC_POP();
    return result;
}


// sometimes in GDB you want to find out what code would be created from a mi
extern "C" JL_DLLEXPORT_CODEGEN jl_code_info_t *jl_gdbdumpcode(jl_method_instance_t *mi) JL_CANSAFEPOINT
{
    jl_llvmf_dump_t llvmf_dump;
    size_t world = jl_current_task->world_age;
    JL_STREAM *stream = (JL_STREAM*)STDERR_FILENO;

    jl_code_info_t *src = jl_gdbcodetyped1(mi, world);
    JL_GC_PUSH1(&src);

    jl_printf(stream, "---- dumping IR for ----\n");
    jl_static_show(stream, (jl_value_t*)mi);
    jl_printf(stream, "\n----\n");

    jl_printf(stream, "\n---- unoptimized IR ----\n");
    jl_get_llvmf_defn(&llvmf_dump, mi, src, 0, false, nullptr, jl_default_cgparams);
    if (llvmf_dump.F) {
        jl_value_t *ir = jl_dump_function_ir(&llvmf_dump, 0, 1, "source");
        if (ir != NULL && jl_is_string(ir))
            jl_printf(stream, "%s", jl_string_data(ir));
    }
    jl_printf(stream, "\n----\n");

    jl_printf(stream, "\n---- optimized IR ----\n");
    jl_get_llvmf_defn(&llvmf_dump, mi, src, 0, true, nullptr, jl_default_cgparams);
    if (llvmf_dump.F) {
        jl_value_t *ir = jl_dump_function_ir(&llvmf_dump, 0, 1, "source");
        if (ir != NULL && jl_is_string(ir))
            jl_printf(stream, "%s", jl_string_data(ir));
    }
    jl_printf(stream, "\n----\n");

    jl_printf(stream, "\n---- assembly ----\n");
    jl_get_llvmf_defn(&llvmf_dump, mi, src, 0, true, nullptr, jl_default_cgparams);
    if (llvmf_dump.F) {
        jl_value_t *ir = jl_dump_function_asm(&llvmf_dump, 0, "", "source", 0, true);
        if (ir != NULL && jl_is_string(ir))
            jl_printf(stream, "%s", jl_string_data(ir));
    }
    jl_printf(stream, "\n----\n");
    JL_GC_POP();

    return src;
}

// --- native code info, and dump function to IR and ASM ---
// Get pointer to llvm::Function instance, compiling if necessary
// for use in reflection from Julia.
// This is paired with jl_dump_function_ir and jl_dump_function_asm, either of which will free all memory allocated here
extern "C" JL_DLLEXPORT_CODEGEN
void jl_get_llvmf_defn_impl(jl_llvmf_dump_t *dump, jl_method_instance_t *mi, jl_code_info_t *src, char getwrapper, char optimize, const char *llvm_options, const jl_cgparams_t params)
{
    // emit this function into a new llvm module
    jl_task_t *ct = jl_current_task;
    dump->F = nullptr;
    dump->TSM = nullptr;
    dump->pass_output = nullptr;
    if (src && jl_is_code_info(src)) {
        const auto &DL = jl_ExecutionEngine->getDataLayout();
        const auto &TT = jl_ExecutionEngine->getTargetTriple();
        auto ctx = std::make_unique<LLVMContext>();
        auto mod = jl_create_llvm_module(name_from_method_instance(mi), *ctx, DL, TT);
        jl_codegen_output_t output{*mod};
        Function *F = nullptr;
        {
            uint64_t compiler_start_time = 0;
            uint8_t measure_compile_time_enabled = jl_atomic_load_relaxed(&jl_measure_compile_time_enabled);
            if (measure_compile_time_enabled)
                compiler_start_time = jl_hrtime();
            output.params = &params;
            output.imaging_mode = jl_options.image_codegen;
            output.temporary_roots = jl_alloc_array_1d(jl_array_any_type, 0);
            JL_GC_PUSH1(&output.temporary_roots);
            std::optional<jl_llvm_functions_t> decls = jl_emit_code(output, mi, src, mi->specTypes, src->rettype);
            emit_always_inline(output, jl_get_method_ir);
            emit_llvmcall_modules(output);
            // while not required, also emit the cfunc thunks, based on the
            // inferred ABIs of their targets in the current latest world,
            // since otherwise it is challenging to see all relevant codes
            // jl_compiled_functions_t compiled_functions;
            size_t latestworld = jl_atomic_load_acquire(&jl_world_counter);
            for (cfunc_decl_t &cfunc : output.cfuncs) {
                jl_value_t *sigt = cfunc.abi.sigt;
                JL_GC_PROMISE_ROOTED(sigt);
                jl_value_t *mi = jl_get_specialization1((jl_tupletype_t*)sigt, latestworld);
                if (mi == jl_nothing)
                    continue;
                jl_code_instance_t *codeinst = jl_type_infer((jl_method_instance_t*)mi, latestworld, SOURCE_MODE_NOT_REQUIRED, jl_options.trim);
                if (codeinst == nullptr || output.ci_funcs.count(codeinst))
                    continue;
                jl_emit_codedecls(output, codeinst);
            }
            generate_cfunc_thunks(output);
            output.temporary_roots_set.clear();
            output.temporary_roots = nullptr;
            JL_GC_POP(); // GC the global_targets array contents now since reflection doesn't need it

            if (decls) {
                jl_codeinst_funcs_t<std::string> decl_names;
                decl_names.invoke_api = decls->invoke_api;
                decl_names.invoke = decls->invoke ? decls->invoke->getName() : "";
                decl_names.specptr = decls->specptr ? decls->specptr->getName() : "";
                // if compilation succeeded, prepare to return the result
                if (!jl_options.image_codegen) {
                    int8_t gc_state = jl_gc_safe_enter(ct->ptls);
                    optimizeDLSyms(output.get_module());
                    jl_gc_safe_leave(ct->ptls, gc_state);
                }
                assert(!verifyLLVMIR(output.get_module()));
                if (optimize) {
                    auto opts = OptimizationOptions::defaults();
                    opts.sanitize_memory = params.sanitize_memory;
                    opts.sanitize_thread = params.sanitize_thread;
                    opts.sanitize_address = params.sanitize_address;
                    PrintOptions print_opts;
                    std::string pass_output_buffer;
                    raw_string_ostream pass_output_stream(pass_output_buffer);
                    if (llvm_options && llvm_options[0] != '\0') {
                        parseLLVMOptions(llvm_options, print_opts);
                        print_opts.out = &pass_output_stream;
                    }
                    NewPM PM{jl_ExecutionEngine->cloneTargetMachine(), getOptLevel(jl_options.opt_level), opts, print_opts};
                    //Safe b/c context lock is held by output
                    PM.run(output.get_module());
                    assert(!verifyLLVMIR(output.get_module()));
                    // Capture pass output (freed by jl_dump_function_ir or jl_dump_function_asm)
                    if (!pass_output_buffer.empty()) {
                        dump->pass_output = strdup(pass_output_buffer.c_str());
                    }
                }
                const std::string *fname;
                if (decls->invoke_api == JL_INVOKE_ARGS || decls->invoke_api == JL_INVOKE_SPARAM)
                    getwrapper = false;
                if (!getwrapper)
                    fname = &decl_names.specptr;
                else
                    fname = &decl_names.invoke;
                F = output.get_module().getFunction(*fname);
                assert(F);
            }
            if (measure_compile_time_enabled) {
                auto end = jl_hrtime();
                jl_atomic_fetch_add_relaxed(&jl_cumulative_compile_time, end - compiler_start_time);
            }
        }
        if (F) {
            dump->TSM = wrap(new orc::ThreadSafeModule(std::move(mod), std::move(ctx)));
            dump->F = wrap(F);
       }
    }
}
