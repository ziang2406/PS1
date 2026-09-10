rm(list = ls())
library(tidyverse)

# Data loading and state-vector construction
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
H_max <- 20L
n <- nrow(z)

# Estimate z_{t+1} = gamma_0 + gamma z_t + e_{t+1}, where t+1 is 12 months
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

# Construct b_z from all 1,129 contemporaneous full-sample observations
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

# Compute a nonnegative integer power of a square matrix
matrix_power <- function(A, exponent) {
  result <- diag(nrow(A))

  if (exponent == 0L) {
    return(result)
  }

  for (power_index in seq_len(exponent)) {
    result <- result %*% A
  }

  result
}

identity_matrix <- diag(nrow(gamma))
stopifnot(rcond(identity_matrix - kappa * gamma) > .Machine$double.eps)
long_run_multiplier <- solve(identity_matrix - kappa * gamma)

e_dg_transpose <- matrix(c(1, 0, 0), nrow = 1)
e_re_transpose <- matrix(c(0, 1, 0), nrow = 1)

b_re <- numeric(H_max)
b_dg <- numeric(H_max)
b_dp <- numeric(H_max)

for (H in seq_len(H_max)) {
  b_t_H <- (
    gamma - kappa^H * matrix_power(gamma, H + 1L)
  ) %*% long_run_multiplier %*% b_z

  b_re[H] <- drop(e_re_transpose %*% b_t_H)
  b_dg[H] <- -drop(e_dg_transpose %*% b_t_H)
  b_dp[H] <- 1 - b_re[H] - b_dg[H]
}

coefficient_results <- tibble(
  H = seq_len(H_max),
  b_re = b_re,
  b_dg = b_dg,
  b_dp = b_dp,
  coefficient_sum = b_re + b_dg + b_dp
)

# Verify the variance-decomposition identity at every horizon
stopifnot(all(abs(coefficient_results$coefficient_sum - 1) < 1e-12))

write_csv(coefficient_results, "code/1c_coeff.csv")

plot_data <- coefficient_results |>
  select(H, b_re, b_dg, b_dp) |>
  pivot_longer(
    cols = c(b_re, b_dg, b_dp),
    names_to = "coefficient",
    values_to = "value"
  ) |>
  mutate(coefficient = factor(coefficient, levels = c("b_re", "b_dg", "b_dp")))

coefficient_plot <- ggplot(
  plot_data,
  aes(x = H, y = value, color = coefficient)
) +
  geom_hline(yintercept = 0, linetype = "dashed") +
  geom_line(linewidth = 0.9) +
  geom_point(size = 1.8) +
  scale_color_manual(
    values = c(
      "b_re" = "red",
      "b_dg" = "blue",
      "b_dp" = "green"
    ),
    labels = c(
      "b_re" = expression(b[re]^{(H)}),
      "b_dg" = expression(b[dg]^{(H)}),
      "b_dp" = expression(b[dp]^{(H)})
    )
  ) +
  scale_x_continuous(breaks = seq_len(H_max)) +
  labs(
    x = "Horizon H (years)",
    y = "Long-run coefficient",
    color = NULL,
    title = "VAR-implied variance decomposition"
  ) +
  theme_classic(base_size = 14) +
  theme(
    legend.position = "right",
    plot.title = element_text(hjust = 0.5)
  )

dir.create("figures", showWarnings = FALSE, recursive = TRUE)
ggsave(
  filename = "figures/1c.png",
  plot = coefficient_plot,
  width = 8,
  height = 5,
  dpi = 300,
  bg = "white"
)

print(gamma_0)
print(gamma)
print(b_z)
print(coefficient_results)
