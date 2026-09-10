rm(list = ls())
library(tidyverse)

# Reproduce the annual VAR(1) setup from question 1c
EQ <- read.csv("EQ Dataset.csv")
state_names <- c("dg", "re", "dp")

stopifnot(
  all(c("YEAR", "MONTH", state_names) %in% names(EQ)),
  nrow(EQ) == 1129L
)

z <- as.matrix(EQ[, state_names])
month_index <- 12L * EQ$YEAR + EQ$MONTH

stopifnot(
  all(is.finite(z)),
  all(diff(month_index) == 1L)
)

step_yr <- 12L
n <- nrow(z)
t_index <- seq_len(n - step_yr)
z_t <- z[t_index, , drop = FALSE]
z_t_plus_1 <- z[t_index + step_yr, , drop = FALSE]

var_model <- lm(z_t_plus_1 ~ z_t)
var_coefficients <- coef(var_model)

stopifnot(qr(cbind(1, z_t))$rank == 4L)

gamma_0 <- matrix(
  var_coefficients[1, ],
  ncol = 1,
  dimnames = list(state_names, "intercept")
)

gamma <- t(var_coefficients[-1, , drop = FALSE])
dimnames(gamma) <- list(state_names, state_names)

# Construct b_z using all 1,129 contemporaneous observations
dp <- z[, "dp"]
dp_bar <- mean(dp)
var_dp <- var(dp)

b_z <- matrix(
  vapply(
    state_names,
    function(variable) cov(dp, z[, variable]) / var_dp,
    numeric(1)
  ),
  ncol = 1,
  dimnames = list(state_names, "beta")
)

kappa <- 1 / (1 + exp(dp_bar))

stopifnot(
  identical(dim(gamma_0), c(3L, 1L)),
  identical(dim(gamma), c(3L, 3L)),
  identical(dim(b_z), c(3L, 1L))
)

# At H = infinity, kappa^H gamma^(H+1) vanishes
identity_matrix <- diag(nrow(gamma))
discounted_var_matrix <- identity_matrix - kappa * gamma
spectral_radius <- max(Mod(eigen(kappa * gamma, only.values = TRUE)$values))
stopifnot(
  rcond(discounted_var_matrix) > .Machine$double.eps,
  spectral_radius < 1
)

b_t_infinity <- gamma %*% solve(discounted_var_matrix) %*% b_z

e_dg_transpose <- matrix(c(1, 0, 0), nrow = 1)
e_re_transpose <- matrix(c(0, 1, 0), nrow = 1)

b_re_infinity <- drop(e_re_transpose %*% b_t_infinity)
b_dg_infinity <- -drop(e_dg_transpose %*% b_t_infinity)
b_dp_infinity <- 1 - b_re_infinity - b_dg_infinity
numerical_tolerance <- sqrt(.Machine$double.eps)
b_dp_is_zero <- abs(b_dp_infinity) <= numerical_tolerance

coefficient_results <- tibble(
  H = Inf,
  b_re = b_re_infinity,
  b_dg = b_dg_infinity,
  b_dp = b_dp_infinity,
  coefficient_sum = b_re_infinity + b_dg_infinity + b_dp_infinity,
  b_dp_is_zero = b_dp_is_zero
)

stopifnot(
  all(is.finite(c(b_re_infinity, b_dg_infinity, b_dp_infinity))),
  abs(coefficient_results$coefficient_sum - 1) < 1e-12
)

write_csv(coefficient_results, "code/1d.csv")

latex_table <- c(
  "\\begin{table}[htbp]",
  "  \\centering",
  "  \\caption{VAR-implied infinite-horizon coefficients}",
  "  \\label{tab:q1d}",
  "  \\begin{tabular}{lr}",
  "    \\toprule",
  "    Component & Coefficient \\\\",
  "    \\midrule",
  sprintf("    $b_{re}^{(\\infty)}$ & %.6f \\\\", b_re_infinity),
  sprintf("    $b_{dg}^{(\\infty)}$ & %.6f \\\\", b_dg_infinity),
  "    \\bottomrule",
  "  \\end{tabular}",
  "\\end{table}"
)

dir.create("figures", showWarnings = FALSE, recursive = TRUE)
writeLines(latex_table, "figures/1d.tex")

cat(paste(latex_table, collapse = "\n"), "\n")
if (!b_dp_is_zero) {
  warning(
    sprintf(
      paste0(
        "Validation check failed: b_dp^(infinity) = %.10f, ",
        "which is not zero at numerical tolerance %.3g."
      ),
      b_dp_infinity,
      numerical_tolerance
    ),
    call. = FALSE
  )
}
print(coefficient_results)
