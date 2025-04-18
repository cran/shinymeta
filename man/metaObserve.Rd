% Generated by roxygen2: do not edit by hand
% Please edit documentation in R/observe.R
\name{metaObserve}
\alias{metaObserve}
\alias{metaObserve2}
\title{Create a meta-reactive observer}
\usage{
metaObserve(
  expr,
  env = parent.frame(),
  quoted = FALSE,
  label = NULL,
  domain = getDefaultReactiveDomain(),
  localize = "auto",
  bindToReturn = FALSE
)

metaObserve2(
  expr,
  env = parent.frame(),
  quoted = FALSE,
  label = NULL,
  domain = getDefaultReactiveDomain()
)
}
\arguments{
\item{expr}{An expression (quoted or unquoted).}

\item{env}{The parent environment for the reactive expression. By default,
this is the calling environment, the same as when defining an ordinary
non-reactive expression. If \code{x} is a quosure and \code{quoted} is \code{TRUE},
then \code{env} is ignored.}

\item{quoted}{If it is \code{TRUE}, then the \code{\link[=quote]{quote()}}ed value of \code{x}
will be used when \code{x} is evaluated. If \code{x} is a quosure and you
would like to use its expression as a value for \code{x}, then you must set
\code{quoted} to \code{TRUE}.}

\item{label}{A label for the observer, useful for debugging.}

\item{domain}{See \link[shiny]{domains}.}

\item{localize}{Whether or not to wrap the returned expression in \code{\link[=local]{local()}}.
The default, \code{"auto"}, only wraps expressions with a top-level \code{\link[=return]{return()}}
statement (i.e., return statements in anonymized functions are ignored).}

\item{bindToReturn}{For non-\code{localize}d expressions, should an assignment
of a meta expression be applied to the \emph{last child} of the top-level \verb{\\\{} call?}
}
\value{
A function that, when called in meta mode (i.e. inside
\code{\link[=expandChain]{expandChain()}}), will return the code in quoted form. If this function is
ever called outside of meta mode, it throws an error, as it is definitely
being called incorrectly.
}
\description{
Create a \code{\link[shiny:observe]{shiny::observe()}}r that, when invoked with meta-mode activated
(i.e. called within \code{\link[=withMetaMode]{withMetaMode()}} or \code{\link[=expandChain]{expandChain()}}), returns a partially
evaluated code expression. Outside of meta-mode, \code{metaObserve()} is
equivalent to \code{observe()} (it fully evaluates the given expression).
}
\details{
If you wish to capture specific code inside of \code{expr} (e.g. ignore
code that has no meaning outside shiny, like \code{\link[shiny:req]{shiny::req()}}), use
\code{metaObserve2()} in combination with \code{metaExpr()}. When using
\code{metaObserve2()}, \code{expr} must return a \code{metaExpr()}.
}
\examples{

# observers execute 'immediately'
x <- 1
mo <- metaObserve({
  x <<- x + 1
})
getFromNamespace("flushReact", "shiny")()
print(x)

# It only makes sense to invoke an meta-observer
# if we're in meta-mode (i.e., generating code)
expandChain(mo())

# Intentionally produces an error
\dontrun{mo()}

}
\seealso{
\code{\link[=metaExpr]{metaExpr()}}, \code{\link[=dotdot]{..}}
}
