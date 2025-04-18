.globals <- new.env(parent = emptyenv())

# This is a global hook for intercepting meta-mode reads of metaReactive/2.
# The first argument is the (delayed eval) code result, and rexpr is the
# metaReactive/2 object itself. If evaluation of x is not triggered by the
# hook function, then the metaReactive/2 code will not execute/be expanded.
#
# The return value should be a code object.
.globals$rexprMetaReadFilter <- function(x, rexpr) {
  x
}

#' Create a meta-reactive expression
#'
#' Create a [shiny::reactive()] that, when invoked with meta-mode activated
#' (i.e. called within [withMetaMode()] or [expandChain()]), returns a code
#' expression (instead of evaluating that expression and returning the value).
#'
#' @details If you wish to capture specific code inside of `expr` (e.g. ignore
#'   code that has no meaning outside shiny, like [shiny::req()]), use
#'   `metaReactive2()` in combination with `metaExpr()`. When using
#'   `metaReactive2()`, `expr` must return a `metaExpr()`.
#'
#' If `varname` is unspecified, [srcref]s are used in attempt to infer the name
#' bound to the meta-reactive object. In order for this inference to work, the
#' `keep.source` [option] must be `TRUE` and `expr` must begin with `\{`.
#'
#' @param varname An R variable name that this object prefers to be named when
#' its code is extracted into an R script. (See also: [expandChain()])
#'
#' @param inline If `TRUE`, during code expansion, do not declare a variable for
#' this object; instead, inline the code into every call site. Use this to avoid
#' introducing variables for very simple expressions. (See also: [expandChain()])
#'
#' @inheritParams shiny::reactive
#' @inheritParams metaExpr
#' @return A function that, when called in meta mode (i.e. inside
#'   [expandChain()]), will return the code in quoted form. When called outside
#'   meta mode, it acts the same as a regular [shiny::reactive()] expression
#'   call.
#' @export
#' @seealso [metaExpr()], [`..`][shinymeta::dotdot]
#' @examples
#'
#' library(shiny)
#' options(shiny.suppressMissingContextError = TRUE)
#'
#' input <- list(x = 1)
#'
#' y <- metaReactive({
#'   req(input$x)
#'   a <- ..(input$x) + 1
#'   b <- a + 1
#'   c + 1
#' })
#'
#' withMetaMode(y())
#' expandChain(y())
#'
#' y <- metaReactive2({
#'   req(input$x)
#'
#'   metaExpr({
#'     a <- ..(input$x) + 1
#'     b <- a + 1
#'     c + 1
#'   }, bindToReturn = TRUE)
#' })
#'
#' expandChain(y())
#'
metaReactive <- function(expr, env = parent.frame(), quoted = FALSE,
  varname = NULL, domain = shiny::getDefaultReactiveDomain(), inline = FALSE,
  localize = "auto", bindToReturn = FALSE) {

  if (!quoted) {
    expr <- substitute(expr)
    quoted <- TRUE
  }

  varname <- exprToVarname(expr, varname, inline, "metaReactive")

  # Need to wrap expr with shinymeta:::metaExpr, but can't use rlang/!! to do
  # so, because we want to keep any `!!` contained in expr intact (i.e. too
  # early to perform expansion of expr here).
  #
  # Even though expr itself is quoted, wrapExpr will effectively unquote it by
  # interpolating it into the `metaExpr()` call, thus quoted = FALSE.
  expr <- wrapExpr(shinymeta::metaExpr, expr, quoted = FALSE, localize = localize, bindToReturn = bindToReturn)

  metaReactiveImpl(expr = expr, env = env, varname = varname, domain = domain, inline = inline)
}


#' @export
#' @rdname metaReactive
metaReactive2 <- function(expr, env = parent.frame(), quoted = FALSE,
  varname = NULL, domain = shiny::getDefaultReactiveDomain(), inline = FALSE) {

  if (!quoted) {
    expr <- substitute(expr)
    quoted <- TRUE
  }

  varname <- exprToVarname(expr, varname, inline, "metaReactive2")

  metaReactiveImpl(expr = expr, env = env, varname = varname, domain = domain, inline = inline)
}

exprToVarname <- function(expr, varname = NULL, inline, objectType = "metaReactive") {

  if (is.null(varname)) {
    if (inline) return("anonymous")

    srcref <- attr(expr, "srcref", exact = TRUE)
    if (is.null(srcref)) {
      if (identical(getOption("keep.source"), FALSE)) {
        warning(
          "Unable to infer variable name for ", objectType, " when the option ",
          "keep.source is FALSE. Either set `options(keep.source = TRUE)` ",
          "or specify `varname` in ", objectType,
          call. = FALSE
        )
      } else if (!rlang::is_call(expr, "{")) {
        warning(
          "Unable to infer variable name for ", objectType, " when `expr` does not ",
          "begin with `{`. Either start `expr` with `{` or specify `varname` in ",
          objectType,
          call. = FALSE
        )
      } else {
        warning(
          "Unable to infer variable name for ", objectType, " because no srcref ",
          "is available. Please report an issue to https://github.com/rstudio/shinymeta/issues/new",
          call. = FALSE
        )
      }
    }

    varname <- mrexprSrcrefToLabel(srcref[[1]], defaultLabel = NULL)
  } else {
    if (!is.character(varname) || length(varname) != 1 || is.na(varname) || nchar(varname) == 0) {
      stop("varname must be a non-empty string", call. = FALSE)
    }
  }
  varname
}

metaReactiveImpl <- function(expr, env, varname, domain, inline) {
  force(expr)
  force(env)
  force(varname)
  force(domain)
  force(inline)

  r_normal <- rlang::inject(
    shiny::reactive(!!rlang::new_quosure(expr, env = env), label = varname, domain = domain)
  )

  r_meta <- function() {
    shiny::withReactiveDomain(domain, {
      eval(expr, envir = new.env(parent = env))
    })
  }

  self <- structure(
    function() {
      metaDispatch(
        normal = {
          r_normal()
        },
        meta = {
          .globals$rexprMetaReadFilter(r_meta(), self)
        }
      )
    },
    class = c("shinymeta_reactive", "shinymeta_object", "reactive", "function"),
    shinymetaVarname = varname,
    shinymetaUID = getFromNamespace("createUniqueId", "shiny")(8),
    shinymetaDomain = domain,
    shinymetaInline = inline
  )
  self
}

#' Run/capture non-reactive code for side effects
#'
#' Most apps start out with setup code that is non-reactive, such as
#' [`library()`][base::library()] calls, loading of static data into local
#' variables, or [`source`][base::source()]-ing of supplemental R scripts.
#' `metaAction` provides a convenient way to run such code for its side effects
#' (including declaring new variables) while making it easy to export that code
#' using [expandChain()]. Note that `metaAction` executes code directly in the
#' `env` environment (which defaults to the caller's environment), so any local
#' variables that are declared in the `expr` will be available outside of
#' `metaAction` as well.
#'
#' @inheritParams metaExpr
#'
#' @param expr A code expression that will immediately be executed (before the
#'   call to `metaAction` returns), and also stored for later retrieval (i.e.
#'   meta mode).
#' @return A function that, when called in meta mode (i.e. inside
#'   [expandChain()]), will return the code in quoted form. If this function is
#'   ever called outside of meta mode, it throws an error, as it is definitely
#'   being called incorrectly.
#'
#' @examples
#'
#' setup <- metaAction({
#'   library(stats)
#'
#'   "# Set the seed to ensure repeatable randomness"
#'   set.seed(100)
#'
#'   x <- 1
#'   y <- 2
#' })
#'
#' # The action has executed
#' print(x)
#' print(y)
#'
#' # And also you can emit the code
#' expandChain(
#'   setup()
#' )
#'
#' @export
metaAction <- function(expr, env = parent.frame(), quoted = FALSE) {
  force(env)

  if (!quoted) {
    expr <- substitute(expr)
    quoted <- TRUE
  }

  # Need to wrap expr with shinymeta:::metaExpr, but can't use rlang/!! to do
  # so, because we want to keep any `!!` contained in expr intact (i.e. too
  # early to perform expansion of expr here).
  expr <- wrapExpr(shinymeta::metaExpr, expr)

  eval(expr, envir = env)
  function() {
    metaDispatch(
      normal = {
        stop("Meta mode must be activated when calling the function returned by `metaAction()`: did you mean to call this function inside of `expandChain()`?")
      },
      meta = {
        eval(expr, envir = env)
      }
    )
  }
}

#' @export
print.shinymeta_reactive <- function(x, ...) {
  cat("metaReactive:", attr(x, "shinymetaVarname"), "\n", sep = "")
}

# A global variable that can be one of three values:
# 1. FALSE - metaExpr() should return its EVALUATED expr
# 2. TRUE - metaExpr() should return its QUOTED expr
# 3. "mixed" - same as TRUE, but see below
#
# The "mixed" exists to serve cases like metaReactive2. In cases
# where calls to metaReactives are encountered inside of metaReactive2
# but outside of metaExpr, those metaReactives should be evaluated in
# non-meta mode (i.e. metaMode(FALSE)).
#
# See metaDispatch for more details on mixed mode.
metaMode <- local({
  value <- FALSE
  function(x) {
    if (missing(x)) {
      value
    } else {
      if (!isTRUE(x) && !is_false(x) && !identical(x, "mixed")) {
        stop("Invalid metaMode() value: legal values are TRUE, FALSE, and \"mixed\"")
      }
      value <<- x
    }
  }
})

# More-specific replacement for switch() on the value of metaMode().
#
# This gives us a single place to update if we need to modify the set of
# supported metaMode values.
switchMetaMode <- function(normal, meta, mixed) {
  if (missing(normal) || missing(meta) || missing(mixed)) {
    stop("switchMetaMode call was missing required argument(s)")
  }

  mode <- metaMode()
  if (isTRUE(mode)) {
    meta
  } else if (is_false(mode)) {
    normal
  } else if (identical(mode, "mixed")) {
    mixed
  } else {
    stop("Illegal metaMode detected: ", format(mode))
  }
}

# metaDispatch implements the innermost if/switch for meta-reactive objects:
# metaReactive/metaReactive2, metaObserve/metaObserve2, metaRender/metaRender2.
#
# We basically want to detect nested calls to `metaDispatch` without an
# intervening `withMetaMode(TRUE)` or `metaExpr`, and treat those cases as
# metaMode(FALSE).
#
# mr1 <- metaReactive({
#   1 + 1
# })
#
# mr2 <- metaReactive2({
#   mr1() # returns 2
#   metaExpr(
#     ..(mr1()) # returns quote(1 + 1)
#   )
# })
#
# withMetaMode(mr2())
metaDispatch <- function(normal, meta) {
  switchMetaMode(
    normal = {
      force(normal)
    },
    meta = {
      withMetaMode(meta, "mixed")
    },
    mixed = {
      withMetaMode(normal, FALSE)
    }
  )
}

#' Evaluate an expression with meta mode activated
#'
#' @param expr an expression.
#' @param mode whether or not to evaluate expression in meta mode.
#' @return The result of evaluating `expr`.
#' @seealso [expandChain()]
#' @export
withMetaMode <- function(expr, mode = TRUE) {
  origVal <- metaMode()
  if (!identical(origVal, mode)) {
    metaMode(mode)
    on.exit(metaMode(origVal), add = TRUE)
  }

  if (switchMetaMode(normal = FALSE, meta = TRUE, mixed = FALSE)) {
    expr <- prefix_meta_classes(expr)
  }

  force(expr)
}

#' The dot-dot operator
#'
#' In shinymeta, `..()` is designed for _annotating_ portions of code
#' inside a `metaExpr` (or its higher-level friends `metaReactive`,
#' `metaObserve`, and `metaRender`). At run time, these `meta-` functions search for
#' `..()` calls and replace them with something else (see Details). Outside
#' of these `meta-` functions, `..()` is not defined, so one must take extra care when
#' interrogating any code within a `meta-` function that contains `..()` (see Debugging).
#'
#' As discussed in the [Code Generation](https://rstudio.github.io/shinymeta/articles/code-generation.html)
#' vignette, `..()` is used to mark reactive reads and unquote expressions inside
#' `metaExpr` (or its higher-level friends `metaReactive`, `metaObserve`, and `metaRender`).
#' The actual behavior of `..()` depends on the current
#' [mode of execution](https://rstudio.github.io/shinymeta/articles/code-generation.html#execution):
#'
#' * __Normal execution__: the `..()` call is stripped from the expression before evaluation.
#' For example, `..(dataset())` becomes `dataset()`, and `..(format(Sys.Date()))` becomes
#' `format(Sys.Date())`.
#'
#' * __Meta execution__ (as in [expandChain()]): reactive reads are replaced with a suitable
#' name or value (i.e. `..(dataset())` becomes `dataset` or similar) and other code is
#' replaced with its result (`..(format(Sys.Date()))` becomes e.g. `"2019-08-06"`).
#'
#' @section Debugging:
#' If `..()` is called in a context where it isn't defined (that is, outside of a meta-expression),
#' you'll see an error like: "..() is only defined inside shinymeta meta-expressions".
#' In practice, this problem can manifest itself in at least 3 different ways:
#'
#' 1. Execution is halted, perhaps by inserting `browser()`, and from inside the `Browse>` prompt,
#' `..()` is called directly. This is also not allowed, because the purpose of `..()` is to be
#' searched-and-replaced away _before_ `metaExpr` begins executing the code. As a result,
#' if you want to interrogate code that contains `..()` at the `Browse>` prompt,
#' make sure it's wrapped in `metaExpr` before evaluating it. Also, note that when
#' stepping through a `metaExpr` at the `Browse>` prompt with `n`, the debugger
#' will echo the actual code that's evaluated during normal execution (i.e., `..()` is stripped),
#' so that's another option for interrogating what happens during normal execution.
#' On the other hand, if you are wanting to interrogate what happens during meta-execution,
#' you can wrap a `metaExpr` with `expandChain()`.
#'
#' 2. `..()` is used in a non-`metaExpr` portions of `metaReactive2`, `metaObserve2`, and
#' `metaRender2`. As discussed in [The execution model](https://rstudio.github.io/shinymeta/articles/code-generation.html#execution),
#' non-`metaExpr` portions of `-2` variants always use normal execution and are completely
#' ignored at code generation time, so `..()` isn't needed in this context.
#'
#' 3. Crafted a bit of code that uses `..()` in a way that was too clever for
#' shinymeta to understand. For example, `lapply(1:5, ..)` is syntactically valid R code,
#' but it's nonsense from a shinymeta perspective.
#'
#' @seealso [metaExpr()], [metaReactive()], [metaObserve()], [metaRender()]
#'
#' @param expr A single code expression. Required.
#' @return `expr`, but annotated.
#'
#' @rdname dotdot
#' @name dotdot
#' @keywords internal
#' @export
.. <- function(expr) {
  stop(call. = FALSE,
      "The ..() function is not defined outside of a `metaExpr` context ",
      "(or its higher-level friends `metaReactive`, `metaObserve`, and `metaRender`). ",
      "You might need to wrap this code inside a `metaExpr` before evaluating it ",
      "see ?shinymeta::.. for more details."
  )
}

#' Mark an expression as a meta-expression
#'
#'
#'
#' @param expr An expression (quoted or unquoted).
#' @param env An environment.
#' @param quoted Is the expression quoted? This is useful when you want to use an expression
#' that is stored in a variable; to do so, it must be quoted with [`quote()`].
#' @param localize Whether or not to wrap the returned expression in [`local()`].
#' The default, `"auto"`, only wraps expressions with a top-level [`return()`]
#' statement (i.e., return statements in anonymized functions are ignored).
#' @param bindToReturn For non-`localize`d expressions, should an assignment
#' of a meta expression be applied to the _last child_ of the top-level `\{` call?
#' @return If inside meta mode, a quoted form of `expr` for use inside of
#'   [metaReactive2()], [metaObserve2()], or [metaRender2()]. Otherwise, in
#'   normal execution, the result of evaluating `expr`.
#'
#' @seealso [metaReactive2()], [metaObserve2()], [metaRender2()], [`..`][shinymeta::dotdot]
#' @export
metaExpr <- function(expr, env = parent.frame(), quoted = FALSE, localize = "auto", bindToReturn = FALSE) {

  if (!quoted) {
    expr <- substitute(expr)
    quoted <- TRUE
  }

  if (switchMetaMode(normal = TRUE, meta = FALSE, mixed = FALSE)) {
    expr <- cleanExpr(expr)
    return(eval(expr, envir = env))
  }

  # metaExpr() moves us from mixed to meta state
  withMetaMode(mode = TRUE, {
    expr <- comment_flags(expr)
    expr <- expandExpr(expr, env)
    expr <- strip_outer_brace(expr)

    # Note that bindToReturn won't make sense for a localized call,
    # so determine we need local scope first, then add a special class
    # (we don't yet have the name for binding the return value)
    expr <- add_local_scope(expr, localize)

    # Apply bindToReturn rules, if relevant
    expr <- bind_to_return(expr)

    # TODO: let user opt-out of comment elevation
    # (I _think_ this is always safe)?
    expr <- elevate_comments(expr)

    # flag the call so that we know to bind next time we see this call
    # inside an assign call, we should modify it
    if (bindToReturn && rlang::is_call(expr, "{")) {
      expr <- prefix_class(expr, "bindToReturn")
    }

    prefix_meta_classes(expr)
  })
}


#' @rdname expandChain
#' @name expandChain
#' @export
newExpansionContext <- function() {
  self <- structure(
    list(
      uidToVarname = fastmap::fastmap(missing_default = NULL),
      seenVarname = fastmap::fastmap(missing_default = FALSE),
      uidToSubstitute = fastmap::fastmap(missing_default = NULL),
      # Function to make a (hopefully but not guaranteed to be new) varname
      makeVarname = local({
        nextVarId <- 0L
        function() {
          nextVarId <<- nextVarId + 1L
          paste0("var_", nextVarId)
        }
      }),
      substituteMetaReactive = function(mrobj, callback) {
        if (!inherits(mrobj, "shinymeta_reactive")) {
          stop(call. = FALSE, "Attempted to substitute an object that wasn't a metaReactive")
        }
        if (!is.function(callback) || length(formals(callback)) != 0) {
          stop(call. = FALSE, "Substitution callback should be a function that takes 0 args")
        }

        uid <- attr(mrobj, "shinymetaUID", exact = TRUE)

        if (!is.null(self$uidToVarname$get(uid))) {
          stop(call. = FALSE, "Attempt to substitute a metaReactive object that's already been rendered into code")
        }

        self$uidToSubstitute$set(uid, callback)
        invisible(self)
      }
    ),
    class = "shinymetaExpansionContext"
  )
  self
}

#' @export
print.shinymetaExpansionContext <- function(x, ...) {
  map <- x$uidToVarname
  cat(sprintf("%s [id: %s]", map$mget(map$keys()), map$keys()), sep = "\n")
}

#' Expand code objects
#'
#' Use `expandChain` to write code out of one or more metaReactive objects.
#' Each meta-reactive object (expression, observer, or renderer) will cause not
#' only its own code to be written, but that of its dependencies as well.
#'
#' @param ... All arguments must be unnamed, and must be one of: 1) calls to
#'   meta-reactive objects, 2) comment string (e.g. `"# A comment"`), 3)
#'   language object (e.g. `quote(print(1 + 1))`), or 4) `NULL` (which will be
#'   ignored). Calls to meta-reactive objects can optionally be [invisible()],
#'   see Details.
#' @param .expansionContext Accept the default value if calling `expandChain` a
#'   single time to generate a corpus of code; or create an expansion context
#'   object using `newExpansionContext()` and pass it to multiple related calls
#'   of `expandChain`. See Details.
#'
#' @return The return value of `expandChain()` is a code object that's suitable for
#'   printing or passing to [displayCodeModal()], [buildScriptBundle()], or
#'   [buildRmdBundle()].
#'
#'   The return value of `newExpansionContext` is an object that should be
#'   passed to multiple `expandChain()` calls.
#'
#' @references <https://rstudio.github.io/shinymeta/articles/code-generation.html>
#'
#' @details
#'
#' There are two ways to extract code from meta objects (i.e. [metaReactive()],
#' [metaObserve()], and [metaRender()]): `withMetaMode()` and `expandChain()`.
#' The simplest is `withMetaMode(obj())`, which crawls the tree of meta-reactive
#' dependencies and expands each `..()` in place.
#'
#' For example, consider these meta objects:
#'
#' ```
#'     nums <- metaReactive({ runif(100) })
#'     obs <- metaObserve({
#'       summary(..(nums()))
#'       hist(..(nums()))
#'     })
#' ```
#'
#' When code is extracted using `withMetaMode`:
#' ```
#'     withMetaMode(obs())
#' ```
#'
#' The result looks like this:
#'
#' ```
#'     summary(runif(100))
#'     plot(runif(100))
#' ```
#'
#' Notice how `runif(100)` is inlined wherever `..(nums())`
#' appears, which is not desirable if we wish to reuse the same
#' values for `summary()` and `plot()`.
#'
#' The `expandChain` function helps us workaround this issue
#' by assigning return values of `metaReactive()` expressions to
#' a name, then replaces relevant expansion (e.g., `..(nums())`)
#' with the appropriate name (e.g. `nums`).
#'
#' ```
#'     expandChain(obs())
#' ```
#'
#' The result looks like this:
#'
#' ```
#'     nums <- runif(100)
#'     summary(nums)
#'     plot(nums)
#' ```
#'
#' You can pass multiple meta objects and/or comments to `expandChain`.
#'
#' ```
#'     expandChain(
#'       "# Generate values",
#'       nums(),
#'       "# Summarize and plot",
#'       obs()
#'     )
#' ```
#'
#' Output:
#'
#' ```
#'     # Load data
#'     nums <- runif(100)
#'     nums
#'     # Inspect data
#'     summary(nums)
#'     plot(nums)
#' ```
#'
#' You can suppress the printing of the `nums` vector in the previous example by
#' wrapping the `nums()` argument to `expandChain()` with `invisible(nums())`.
#'
#' @section Preserving dependencies between `expandChain()` calls:
#'
#' Sometimes we may have related meta objects that we want to generate code for,
#' but we want the code for some objects in one code chunk, and the code for
#' other objects in another code chunk; for example, you might be constructing
#' an R Markdown report that has a specific place for each code chunk.
#'
#' Within a single `expandChain()` call, all `metaReactive` objects are
#' guaranteed to only be declared once, even if they're declared on by multiple
#' meta objects; but since we're making two `expandChain()` calls, we will end
#' up with duplicated code. To remove this duplication, we need the second
#' `expandChain` call to know what code was emitted in the first `expandChain`
#' call.
#'
#' We can achieve this by creating an "expansion context" and sharing it between
#' the two calls.
#'
#' ```
#'     exp_ctx <- newExpansionContext()
#'     chunk1 <- expandChain(.expansionContext = exp_ctx,
#'       invisible(nums())
#'     )
#'     chunk2 <- expandChain(.expansionContext = exp_ctx,
#'       obs()
#'     )
#' ```
#'
#' After this code is run, `chunk1` contains only the definition of `nums` and
#' `chunk2` contains only the code for `obs`.
#'
#' @section Substituting `metaReactive` objects:
#'
#' Sometimes, when generating code, we want to completely replace the
#' implementation of a `metaReactive`. For example, our Shiny app might contain
#' this logic, using [shiny::fileInput()]:
#'
#' ```
#'     data <- metaReactive2({
#'       req(input$file_upload)
#'       metaExpr(read.csv(..(input$file_upload$datapath)))
#'     })
#'     obs <- metaObserve({
#'       summary(..(data()))
#'     })
#' ```
#'
#' Shiny's file input works by saving uploading files to a temp directory. The
#' file referred to by `input$file_upload$datapath` won't be available when
#' another user tries to run the generated code.
#'
#' You can use the expansion context object to swap out the implementation of
#' `data`, or any other `metaReactive`:
#'
#' ```
#'     ec <- newExpansionContext()
#'     ec$substituteMetaReactive(data, function() {
#'       metaExpr(read.csv("data.csv"))
#'     })
#'
#'     expandChain(.expansionContext = ec, obs())
#' ```
#'
#' Result:
#'
#' ```
#'     data <- read.csv("data.csv")
#'     summary(data)
#' ```
#'
#' Just make sure this code ends up in a script or Rmd bundle that includes the
#' uploaded file as `data.csv`, and the user will be able to reproduce your
#' analysis.
#'
#' The `substituteMetaReactive` method takes two arguments: the `metaReactive`
#' object to substitute, and a function that takes zero arguments and returns a
#' quoted expression (for the nicest looking results, use `metaExpr` to create
#' the expression). This function will be invoked the first time the
#' `metaReactive` object is encountered (or if the `metaReactive` is defined
#' with `inline = TRUE`, then every time it is encountered).
#'
#' @examples
#' input <- list(dataset = "cars")
#'
#' # varname is only required if srcref aren't supported
#' # (R CMD check disables them for some reason?)
#' mr <- metaReactive({
#'   get(..(input$dataset), "package:datasets")
#' })
#'
#' top <- metaReactive({
#'   head(..(mr()))
#' })
#'
#' bottom <- metaReactive({
#'   tail(..(mr()))
#' })
#'
#' obs <- metaObserve({
#'   message("Top:")
#'   summary(..(top()))
#'   message("Bottom:")
#'   summary(..(bottom()))
#' })
#'
#' # Simple case
#' expandChain(obs())
#'
#' # Explicitly print top
#' expandChain(top(), obs())
#'
#' # Separate into two code chunks
#' exp_ctx <- newExpansionContext()
#' expandChain(.expansionContext = exp_ctx,
#'   invisible(top()),
#'   invisible(bottom()))
#' expandChain(.expansionContext = exp_ctx,
#'   obs())
#'
#' @export
expandChain <- function(..., .expansionContext = newExpansionContext()) {
  # As we come across previously unseen objects (i.e. the UID has not been
  # encountered before) we have to make some decisions about what variable name
  # (i.e. varname) to use to represent that object. This varname is either
  # auto-detected based on the metaReactive's variable name, or provided
  # explicitly by the user when the metaReactive is created. (If the object
  # belongs to a module, then we use the module ID to prefix the varname.)
  #
  # But, the desired variable name might already have been used by a different
  # metaReactive (i.e. two objects have the same label). In this case, we can
  # also use a var_1, var_2, etc. (and this is what the code currently does)
  # but it'd be even better to try to disambiguate by using the desired name
  # plus _1, _2, etc. (keep going til you find one that hasn't been used yet).
  #
  # IDEA:
  # A different strategy we could use is to generate a gensym as the label at
  # first, keeping track of the metadata for every gensym (label, module id).
  # Then after the code generation is done, we can go back and see what the
  # best overall set of variable names is. For example, if the same variable
  # name "df" is used within module IDs "one" and "two", we can use "one_df"
  # and "two_df"; but if only module ID "one" is used, we can just leave it
  # as "df". (As opposed to the current strategy, where if "one" and "two"
  # are both used, we end up with "df" and "df_two".)

  # Keep track of what label we have used for each UID we have previously
  # encountered. If a UID isn't found in this map, then we haven't yet
  # encountered it.
  uidToVarname <- .expansionContext$uidToVarname
  # Keep track of what labels we have used, so we can be sure we don't
  # reuse them.
  seenVarname <- .expansionContext$seenVarname

  # As we encounter metaReactives that we depend on (directly or indirectly),
  # we'll append their code to this list (including assigning them to a label).
  dependencyCode <- list()

  # Override the rexprMetaReadFilter while we generate code. This is a filter
  # function that metaReactive/metaReactive2 will call when someone asks them
  # for their meta value. The `x` is the (lazily evaluated) logic for actually
  # generating their code (or retrieving it from cache).
  oldFilter <- .globals$rexprMetaReadFilter
  .globals$rexprMetaReadFilter <- function(x, rexpr) {
    # Read this object's UID.
    uid <- attr(rexpr, "shinymetaUID", exact = TRUE)
    domain <- attr(rexpr, "shinymetaDomain", exact = TRUE)
    inline <- attr(rexpr, "shinymetaInline", exact = TRUE)

    exec <- function() {
      subfunc <- .expansionContext$uidToSubstitute$get(uid)
      if (!is.null(subfunc)) {
        withMetaMode(subfunc())
      } else {
        x
      }
    }

    if (isTRUE(inline)) {
      # The metaReactive doesn't want to have its own variable
      return(exec())
    }

    # Check if we've seen this UID before, and if so, just return the same
    # varname as we used last time.
    varname <- uidToVarname$get(uid)
    if (!is.null(varname)) {
      return(structure(varname, class = "shinymeta_symbol"))
    }

    # OK, we haven't seen this UID before. We need to figure out what variable
    # name to use.

    # Our first choice would be whatever varname the object itself has (the true
    # var name of this metaReactive, or a name the user explicitly provided).
    varname <- attr(rexpr, "shinymetaVarname", exact = TRUE)

    # If there wasn't either a varname or explicitly provided name, just make
    # a totally generic one up.
    if (is.null(varname) || varname == "" || length(varname) != 1) {
      varname <- .expansionContext$makeVarname()
    } else {
      if (!is.null(domain)) {
        varname <- gsub("-", "_", domain$ns(varname))
      }
    }

    # Make sure we don't use a variable name that has already been used.
    while (seenVarname$get(varname)) {
      varname <- .expansionContext$makeVarname()
    }

    # Remember this UID/varname combination for the future.
    uidToVarname$set(uid, varname)
    # Make sure this varname doesn't get used again.
    seenVarname$set(varname, TRUE)

    # Since this is the first time we're seeing this object, now we need to
    # generate its code and store it in our running list of dependencies.
    expr <- rlang::expr(`<-`(!!as.symbol(varname), !!exec()))
    dependencyCode <<- c(dependencyCode, list(expr))

    # This is what we're returning to the caller; whomever wanted the code for
    # this metaReactive is going to get this variable name instead.
    return(structure(varname, class = "shinymeta_symbol"))
  }
  on.exit(.globals$rexprMetaReadFilter <- oldFilter, add = TRUE)

  withMetaMode({
    # Trigger evaluation of the ..., which will also cause dependencyCode to be
    # populated. The value of list(...) should all be code expressions, unless
    # the user passed in something wrong.
    dot_args <- eval(substitute(alist(...)))
    if (!is.null(names(dot_args))) {
      stop(call. = FALSE, "Named ... arguments to expandChain are not supported")
    }

    res <- lapply(seq_along(dot_args), function(i) {
      # Grab the nth element. We do it with this gross `..n` business because
      # we want to make sure we trigger evaluation of the arguments one at a
      # time. We can't use rlang's dots-related functions, because it eagerly
      # expands the `!!` in arguments, which we want to leave alone.
      #
      # Use `withVisible` because invisible() arguments should have their
      # deps inserted, but not their actual code. Note that metaReactives
      # consider *themselves* their own dependencies, so for metaReactive
      # this means the code that assigns it is created (`mr <- ...`),
      # but the additional line for printing it (`mr`) will be suppressed.
      x_vis <- withVisible(eval(as.symbol(paste0("..", i)), envir = environment()))
      x <- x_vis$value

      val <- if (is_comment(x)) {
        do.call(metaExpr, list(rlang::expr({!!x; {}})))
      } else if (inherits(x, "shinymeta_symbol")) {
        as.symbol(x)
      } else if (is.language(x)) {
        x
      } else if (is.null(x)) {
        x
      } else {
        stop(call. = FALSE, "expandChain() understands language objects, comment-strings, and NULL; but not ", class(x)[1], " objects")
      }
      myDependencyCode <- dependencyCode
      dependencyCode <<- list()
      if (x_vis$visible) {
        c(myDependencyCode, list(val))
      } else {
        myDependencyCode
      }
    })
    res <- unlist(res, recursive = FALSE)
    res <- res[!vapply(res, is.null, logical(1))]

    # Expand into a block of code
    metaExpr(as.call(c(list(quote(`{`)), res)), quoted = TRUE)
  })
}


is_output_read <- function(expr) {
  if (!rlang::is_call(expr)) return(FALSE)
  if (length(expr) == 1) expr <- expr[[1]]
  is_dollar <- rlang::is_call(expr, name = "$", n = 2) &&
    rlang::is_symbol(expr[[2]], "output") &&
    rlang::is_symbol(expr[[3]])
  is_bracket <- rlang::is_call(expr, name = "[[", n = 2) &&
    rlang::is_symbol(expr[[2]], "output") &&
    is.character(expr[[3]])
  is_dollar || is_bracket
}

prefix_meta_classes <- function(expr) {
  expr <- prefix_class(expr, "shinyMetaExpr")
  if (is.character(expr)) {
    expr <- prefix_class(expr, "shinyMetaString")
  }
  expr
}

prefix_class <- function (x, y) {
  # Can't set attributes on a symbol, but that's alright because
  # we don't need to flag or compute on symbols
  if (is.symbol(x)) return(x)
  oldClass(x) <- unique(c(y, oldClass(x)))
  x
}

remove_class <- function(x, y) {
  if (is.symbol(x)) return(x)
  oldClass(x) <- setdiff(oldClass(x), y)
  x
}
