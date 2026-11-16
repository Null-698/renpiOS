#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

/* The Renios packs ship libpython and librenpy without Python headers.
 * Each embedded framework links these APIs against its own Python ABI. */
typedef struct _ts PyThreadState;
extern void init_librenpy(void);
extern void Py_InitializeEx(int installSignalHandlers);
extern int Py_IsInitialized(void);
extern PyThreadState *PyEval_SaveThread(void);
extern void PyEval_RestoreThread(PyThreadState *);
extern int PyRun_SimpleString(const char *);
extern int Py_IgnoreEnvironmentFlag;
extern int Py_NoUserSiteDirectory;
#define RUN_GAME "import sys; " \
    "base = sys.argv[0].rsplit('/', 1)[0]; sys.path[:] = [base] + [p for p in sys.path if p != base]; " \
    "import renios_runtime; renios_runtime.play()"
#define STRINGIFY_VALUE(value) #value
#define STRINGIFY(value) STRINGIFY_VALUE(value)
#if RENIOS_PY2
extern int Py_OptimizeFlag;
extern void Py_SetProgramName(char *);
extern void Py_SetPythonHome(char *);
extern void PySys_SetArgvEx(int, char **, int);
extern void PyEval_InitThreads(void);
#else
extern int Py_UTF8Mode;
extern void Py_SetProgramName(const wchar_t *);
extern void Py_SetPythonHome(const wchar_t *);
extern void Py_SetPath(const wchar_t *);
extern void PySys_SetArgvEx(int, wchar_t **, int);
extern wchar_t *Py_DecodeLocale(const char *, size_t *);
extern void PyMem_RawFree(void *);
#endif

static PyThreadState *idlePython;

static int startPython(const char *base, const char *script) {
#if RENIOS_PY2
    char *home = strdup(base);
    char *program = strdup(script);
    if (!home || !program) {
        free(home);
        free(program);
        return -1;
    }
#else
    char *path = NULL;
    if (asprintf(&path, "%s/lib/python%s:%s/lib/python%s.zip:%s", base,
                 "3." STRINGIFY(RENIOS_PY_MINOR), base, "3" STRINGIFY(RENIOS_PY_MINOR), base) < 0) {
        return -1;
    }
    Py_UTF8Mode = 1;
    wchar_t *home = Py_DecodeLocale(base, NULL);
    wchar_t *program = Py_DecodeLocale(script, NULL);
    wchar_t *searchPath = Py_DecodeLocale(path, NULL);
    free(path);
    if (!home || !program || !searchPath) {
        PyMem_RawFree(home);
        PyMem_RawFree(program);
        PyMem_RawFree(searchPath);
        return -1;
    }
    Py_SetPath(searchPath);
    PyMem_RawFree(searchPath);
#endif
    /* Python retains the program and home strings for its lifetime. */
    Py_SetPythonHome(home);
    Py_SetProgramName(program);
    Py_IgnoreEnvironmentFlag = 1;
    Py_NoUserSiteDirectory = 1;
#if RENIOS_PY2
    Py_OptimizeFlag = 2;
#endif
    init_librenpy();
    Py_InitializeEx(0);
    if (!Py_IsInitialized()) { return -1; }
#if RENIOS_PY2
    PyEval_InitThreads();
#endif
    return 0;
}

int renios_engine_play(const char *base, const char *project, const char *saves) {
    char *script = NULL;
    if (asprintf(&script, "%s/main.py", base) < 0) { return -1; }
    if (idlePython) {
        PyEval_RestoreThread(idlePython);
        idlePython = NULL;
    } else if (startPython(base, script) != 0) {
        free(script);
        return -1;
    }

    const char *arguments[] = {script, project, "--savedir", saves};
    enum { argumentCount = sizeof(arguments) / sizeof(arguments[0]) };
    int status = -1;
#if RENIOS_PY2
    char *argv[argumentCount];
    for (int i = 0; i < argumentCount; ++i) { argv[i] = (char *)arguments[i]; }
    PySys_SetArgvEx(argumentCount, argv, 0);
    status = PyRun_SimpleString(RUN_GAME);
#else
    wchar_t *argv[argumentCount] = {0};
    int converted = 0;
    while (converted < argumentCount) {
        argv[converted] = Py_DecodeLocale(arguments[converted], NULL);
        if (!argv[converted]) { break; }
        ++converted;
    }
    if (converted == argumentCount) {
        PySys_SetArgvEx(argumentCount, argv, 0);
        status = PyRun_SimpleString(RUN_GAME);
    }
    for (int i = 0; i < converted; ++i) { PyMem_RawFree(argv[i]); }
#endif
    idlePython = PyEval_SaveThread();
    free(script);
    return status;
}
