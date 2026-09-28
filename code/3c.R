rm(list = ls())

library(data.table)
library(ggplot2)
library(sandwich)

month_number <- function(yyyymm) {
  12L * (yyyymm %/% 100L) + (yyyymm %% 100L)
}

next_yyyymm <- function(yyyymm) {
  year <- yyyymm %/% 100L
  month <- yyyymm %% 100L
  fifelse(month == 12L, (year + 1L) * 100L + 1L, yyyymm + 1L)
}

percent_label <- function(x) {
  sprintf("%.2f%%", 100 * x)
}

breakpoint_names <- paste0("P", seq(10L, 90L, by = 10L))
breakpoint_probabilities <- seq(0.1, 0.9, by = 0.1)

portfolio_types <- data.table(
  TYPE_CODE = c("i", "ii", "iii", "iv", "v"),
  PORTFOLIO_TYPE = c(
    "VW_ANNUAL_NYSE",
    "EW_ANNUAL_NYSE",
    "VW_MONTHLY_NYSE",
    "VW_ANNUAL_GENERAL",
    "EW_MONTHLY_GENERAL"
  ),
  DISPLAY_NAME = c(
    "Value-weighted, annual, NYSE breakpoints",
    "Equal-weighted, annual, NYSE breakpoints",
    "Value-weighted, monthly, NYSE breakpoints",
    "Value-weighted, annual, general breakpoints",
    "Equal-weighted, monthly, general breakpoints"
  )
)

signal_display_names <- c(
  BM_CZ = "BM_CZ",
  MOM_CZ = "MOM_CZ",
  GP_CZ = "GP_CZ"
)

signal_colors <- c(
  BM_CZ = "blue",
  MOM_CZ = "red",
  GP_CZ = "green"
)

# -----------------------------------------------------------------------------
# Read the screened CRSP master file and reconstruct RET_ADJ and monthly ME.
# -----------------------------------------------------------------------------

required_crsp_columns <- c(
  "PERMNO",
  "YYYYMM",
  "SHRCD",
  "EXCHCD",
  "SICCD",
  "DLSTCD",
  "DLRET",
  "PRC",
  "RET",
  "SHROUT"
)

panel <- fread(
  "cleaned_CRSP.csv",
  select = required_crsp_columns,
  colClasses = list(character = c("RET", "DLRET")),
  na.strings = c("", "NA"),
  showProgress = FALSE
)
setnames(panel, toupper(names(panel)))

stopifnot(
  identical(names(panel), required_crsp_columns),
  !anyNA(panel$PERMNO),
  !anyNA(panel$YYYYMM),
  anyDuplicated(panel, by = c("PERMNO", "YYYYMM")) == 0L,
  all(panel$YYYYMM %% 100L >= 1L & panel$YYYYMM %% 100L <= 12L),
  all(panel$SHRCD %in% c(10L, 11L)),
  all(panel$EXCHCD %in% c(1L, 2L, 3L))
)

panel[, RET_NUMERIC := suppressWarnings(as.numeric(RET))]
panel[, DLRET_NUMERIC := suppressWarnings(as.numeric(DLRET))]

ret_nonnumeric_codes <- sort(unique(
  panel[!is.na(RET) & is.na(RET_NUMERIC), RET]
))
dlret_nonnumeric_codes <- sort(unique(
  panel[!is.na(DLRET) & is.na(DLRET_NUMERIC), DLRET]
))

stopifnot(
  all(ret_nonnumeric_codes %chin% c("B", "C")),
  all(dlret_nonnumeric_codes %chin% c("A", "P", "S", "T"))
)

panel[, RETURN_AVAILABILITY := fcase(
  !is.na(RET_NUMERIC) & !is.na(DLRET_NUMERIC), "RET and DLRET",
  is.na(RET_NUMERIC) & !is.na(DLRET_NUMERIC), "DLRET only",
  !is.na(RET_NUMERIC) & is.na(DLRET_NUMERIC), "RET only",
  default = "RET and DLRET missing"
)]

panel[, RET_ADJ := fcase(
  RETURN_AVAILABILITY == "RET and DLRET",
  (1 + RET_NUMERIC) * (1 + DLRET_NUMERIC) - 1,
  RETURN_AVAILABILITY == "DLRET only",
  DLRET_NUMERIC,
  RETURN_AVAILABILITY == "RET only",
  RET_NUMERIC,
  default = NA_real_
)]

panel[, ME := abs(PRC) * SHROUT / 1000]
panel[, MONTH_INDEX := month_number(YYYYMM)]

stopifnot(
  all(is.na(panel$RET_ADJ) | is.finite(panel$RET_ADJ)),
  all(panel$RET_ADJ[!is.na(panel$RET_ADJ)] >= -1),
  all(is.na(panel$ME) | (is.finite(panel$ME) & panel$ME >= 0))
)

# -----------------------------------------------------------------------------
# Read and left-join the three signal files, preserving CRSP as the master.
# -----------------------------------------------------------------------------

read_signal <- function(file, expected_value_name) {
  signal <- fread(
    file,
    na.strings = c("", "NA"),
    showProgress = FALSE
  )
  setnames(signal, toupper(names(signal)))

  stopifnot(
    identical(names(signal), c("PERMNO", "YYYYMM", expected_value_name)),
    !anyNA(signal$PERMNO),
    !anyNA(signal$YYYYMM),
    anyDuplicated(signal, by = c("PERMNO", "YYYYMM")) == 0L,
    all(signal$YYYYMM %% 100L >= 1L &
      signal$YYYYMM %% 100L <= 12L)
  )

  signal
}

gp <- read_signal("GP.csv", "GP")
bmdec <- read_signal("BMdec.csv", "BMDEC")
mom12m <- read_signal("Mom12m.csv", "MOM12M")

source_signal_information <- data.table(
  SIGNAL = c("GP_CZ", "BM_CZ", "MOM_CZ"),
  SOURCE_OBSERVATIONS = c(nrow(gp), nrow(bmdec), nrow(mom12m)),
  SOURCE_PERMNOS = c(
    uniqueN(gp$PERMNO),
    uniqueN(bmdec$PERMNO),
    uniqueN(mom12m$PERMNO)
  ),
  SOURCE_START_YYYYMM = c(
    min(gp$YYYYMM),
    min(bmdec$YYYYMM),
    min(mom12m$YYYYMM)
  ),
  SOURCE_END_YYYYMM = c(
    max(gp$YYYYMM),
    max(bmdec$YYYYMM),
    max(mom12m$YYYYMM)
  ),
  SOURCE_NONFINITE = c(
    sum(!is.finite(gp$GP)),
    sum(!is.finite(bmdec$BMDEC)),
    sum(!is.finite(mom12m$MOM12M))
  )
)

# Update joins are literal left joins because PANEL remains the master table.
panel[gp, GP_RAW := i.GP, on = .(PERMNO, YYYYMM)]
panel[bmdec, BMDEC_RAW := i.BMDEC, on = .(PERMNO, YYYYMM)]
panel[mom12m, MOM12M_RAW := i.MOM12M, on = .(PERMNO, YYYYMM)]

# The student-authored revision treats only non-finite GP values as invalid.
panel[, GP_CZ := fifelse(is.finite(GP_RAW), GP_RAW, NA_real_)]
panel[, BM_CZ := BMDEC_RAW]
panel[, MOM_CZ := MOM12M_RAW]

rm(gp, bmdec, mom12m)
invisible(gc())

# -----------------------------------------------------------------------------
# Parse only the six-digit monthly block of FF.csv and left-join decimal RF.
# -----------------------------------------------------------------------------

ff_lines <- readLines("FF.csv", warn = FALSE)
ff_header_line <- which(grepl("^,Mkt-RF,SMB,HML,RF\\r?$", ff_lines))
ff_monthly_lines <- grep("^[[:space:]]*[0-9]{6},", ff_lines, value = TRUE)

stopifnot(length(ff_header_line) >= 1L, length(ff_monthly_lines) > 0L)

ff <- fread(
  text = paste(
    c(ff_lines[ff_header_line[1L]], ff_monthly_lines),
    collapse = "\n"
  ),
  strip.white = TRUE,
  showProgress = FALSE
)
setnames(ff, 1L, "YYYYMM")
setnames(ff, toupper(names(ff)))
ff <- ff[, .(YYYYMM = as.integer(YYYYMM), RF = as.numeric(RF) / 100)]
setorder(ff, YYYYMM)

stopifnot(
  anyDuplicated(ff, by = "YYYYMM") == 0L,
  !anyNA(ff),
  all(ff$YYYYMM %% 100L >= 1L & ff$YYYYMM %% 100L <= 12L),
  all(diff(month_number(ff$YYYYMM)) == 1L)
)

panel[ff, RF := i.RF, on = "YYYYMM"]

stopifnot(
  !anyNA(panel$RF),
  panel[, uniqueN(RF), by = YYYYMM][, all(V1 == 1L)]
)

rm(ff, ff_lines, ff_monthly_lines)
invisible(gc())

# -----------------------------------------------------------------------------
# Report signal coverage and descriptive statistics in the CRSP master panel.
# -----------------------------------------------------------------------------

summarize_signal <- function(signal_name, raw_name) {
  value <- panel[[signal_name]]
  raw_value <- panel[[raw_name]]
  finite <- is.finite(value)
  finite_value <- value[finite]
  finite_month <- panel$YYYYMM[finite]

  stopifnot(length(finite_value) > 0L)

  data.table(
    SIGNAL = signal_name,
    MASTER_OBSERVATIONS = nrow(panel),
    MATCHED_RAW_OBSERVATIONS = sum(!is.na(raw_value)),
    EXCLUDED_NONFINITE_MATCHED = sum(
      !is.na(raw_value) & !is.finite(raw_value)
    ),
    FINITE_OBSERVATIONS = length(finite_value),
    MISSING_AFTER_CLEANING = sum(!finite),
    SAMPLE_START_YYYYMM = min(finite_month),
    SAMPLE_END_YYYYMM = max(finite_month),
    MEAN = mean(finite_value),
    SD = sd(finite_value),
    MIN = min(finite_value),
    P01 = unname(quantile(finite_value, 0.01, type = 7)),
    P10 = unname(quantile(finite_value, 0.10, type = 7)),
    P25 = unname(quantile(finite_value, 0.25, type = 7)),
    MEDIAN = median(finite_value),
    P75 = unname(quantile(finite_value, 0.75, type = 7)),
    P90 = unname(quantile(finite_value, 0.90, type = 7)),
    P99 = unname(quantile(finite_value, 0.99, type = 7)),
    MAX = max(finite_value)
  )
}

signal_summary <- rbindlist(list(
  summarize_signal("BM_CZ", "BMDEC_RAW"),
  summarize_signal("MOM_CZ", "MOM12M_RAW"),
  summarize_signal("GP_CZ", "GP_RAW")
))
signal_summary <- merge(
  source_signal_information,
  signal_summary,
  by = "SIGNAL",
  all = TRUE,
  sort = FALSE
)

stopifnot(
  signal_summary[SIGNAL == "GP_CZ", SOURCE_NONFINITE] == 24L,
  signal_summary[SIGNAL == "GP_CZ", EXCLUDED_NONFINITE_MATCHED] == 12L,
  all(signal_summary[SIGNAL != "GP_CZ", SOURCE_NONFINITE] == 0L)
)

# -----------------------------------------------------------------------------
# Match formation-month information to an exact next-calendar-month return.
# The sample starts with June 1963 information and July 1963 returns.
# -----------------------------------------------------------------------------

formation_base <- panel[
  YYYYMM >= 196306L & YYYYMM <= 202411L,
  .(
    PERMNO,
    FORMATION_YYYYMM = YYYYMM,
    FORMATION_INDEX = MONTH_INDEX,
    FORMATION_EXCHCD = EXCHCD,
    ME
  )
]

next_returns <- panel[
  YYYYMM >= 196307L &
    YYYYMM <= 202412L &
    is.finite(RET_ADJ) &
    is.finite(RF),
  .(
    PERMNO,
    FORMATION_INDEX = MONTH_INDEX - 1L,
    RETURN_YYYYMM = YYYYMM,
    XRET_ADJ = RET_ADJ - RF
  )
]

realized_sample <- merge(
  formation_base,
  next_returns,
  by = c("PERMNO", "FORMATION_INDEX"),
  all = FALSE,
  sort = FALSE
)
realized_sample[, SORT_YEAR :=
  FORMATION_YYYYMM %/% 100L -
    as.integer(FORMATION_YYYYMM %% 100L <= 5L)]

stopifnot(
  anyDuplicated(
    realized_sample,
    by = c("PERMNO", "FORMATION_YYYYMM", "RETURN_YYYYMM")
  ) == 0L,
  all(realized_sample$RETURN_YYYYMM ==
    next_yyyymm(realized_sample$FORMATION_YYYYMM)),
  all(month_number(realized_sample$RETURN_YYYYMM) ==
    realized_sample$FORMATION_INDEX + 1L),
  all(is.finite(realized_sample$XRET_ADJ)),
  min(realized_sample$RETURN_YYYYMM) == 196307L,
  max(realized_sample$RETURN_YYYYMM) == 202412L
)

rm(formation_base, next_returns)
invisible(gc())

# -----------------------------------------------------------------------------
# Breakpoint construction and deterministic interval assignment.
# Intervals are (-Inf, P10), [P10, P20), ..., [P90, Inf).
# -----------------------------------------------------------------------------

calculate_breakpoints <- function(data, group_column, nyse_only) {
  breakpoint_sample <- if (nyse_only) {
    data[FORMATION_EXCHCD == 1L]
  } else {
    data
  }

  stopifnot(nrow(breakpoint_sample) > 0L)

  breakpoint_sample[
    ,
    {
      values <- quantile(
        SIGNAL_VALUE,
        probs = breakpoint_probabilities,
        type = 7,
        names = FALSE
      )
      c(
        list(N_BREAKPOINT_FIRMS = .N),
        as.list(setNames(values, breakpoint_names))
      )
    },
    by = group_column
  ]
}

assign_deciles <- function(data, group_column, signal_name, frequency) {
  stopifnot(
    nrow(data) > 0L,
    all(is.finite(data$SIGNAL_VALUE)),
    all(data$FORMATION_EXCHCD %in% c(1L, 2L, 3L))
  )

  general_breakpoints <- calculate_breakpoints(
    data,
    group_column,
    nyse_only = FALSE
  )
  nyse_breakpoints <- calculate_breakpoints(
    data,
    group_column,
    nyse_only = TRUE
  )

  general_for_join <- general_breakpoints[
    ,
    c(group_column, breakpoint_names),
    with = FALSE
  ]
  assigned <- merge(
    data,
    general_for_join,
    by = group_column,
    all.x = TRUE,
    sort = FALSE
  )
  stopifnot(!assigned[, anyNA(.SD), .SDcols = breakpoint_names])

  assigned[, DECILE_GENERAL := 1L]
  for (breakpoint_name in breakpoint_names) {
    assigned[
      SIGNAL_VALUE >= get(breakpoint_name),
      DECILE_GENERAL := DECILE_GENERAL + 1L
    ]
  }
  assigned[, (breakpoint_names) := NULL]

  nyse_for_join <- nyse_breakpoints[
    ,
    c(group_column, breakpoint_names),
    with = FALSE
  ]
  assigned <- merge(
    assigned,
    nyse_for_join,
    by = group_column,
    all.x = TRUE,
    sort = FALSE
  )
  stopifnot(!assigned[, anyNA(.SD), .SDcols = breakpoint_names])

  assigned[, DECILE_NYSE := 1L]
  for (breakpoint_name in breakpoint_names) {
    assigned[
      SIGNAL_VALUE >= get(breakpoint_name),
      DECILE_NYSE := DECILE_NYSE + 1L
    ]
  }
  assigned[, (breakpoint_names) := NULL]

  stopifnot(
    all(assigned$DECILE_GENERAL %in% 1:10),
    all(assigned$DECILE_NYSE %in% 1:10)
  )

  format_breakpoints <- function(breakpoints, universe) {
    formatted <- copy(breakpoints)
    if (frequency == "ANNUAL") {
      formatted[, FORMATION_YYYYMM := get(group_column) * 100L + 6L]
    } else {
      formatted[, FORMATION_YYYYMM := get(group_column)]
    }
    formatted[, `:=`(
      SIGNAL = signal_name,
      REBALANCE_FREQUENCY = frequency,
      BREAKPOINT_UNIVERSE = universe
    )]
    if (group_column != "FORMATION_YYYYMM") {
      formatted[, (group_column) := NULL]
    }
    setcolorder(
      formatted,
      c(
        "SIGNAL",
        "REBALANCE_FREQUENCY",
        "BREAKPOINT_UNIVERSE",
        "FORMATION_YYYYMM",
        "N_BREAKPOINT_FIRMS",
        breakpoint_names
      )
    )
    formatted
  }

  list(
    assigned = assigned,
    breakpoints = rbindlist(list(
      format_breakpoints(general_breakpoints, "GENERAL"),
      format_breakpoints(nyse_breakpoints, "NYSE")
    ))
  )
}

calculate_portfolio_returns <- function(
    assigned_returns,
    decile_column,
    signal_name,
    type_code,
    portfolio_type,
    weighting) {
  portfolio_sample <- assigned_returns[
    !is.na(get(decile_column)) & is.finite(XRET_ADJ)
  ]
  portfolio_sample[, DECILE := get(decile_column)]

  if (weighting == "VW") {
    portfolio_sample <- portfolio_sample[is.finite(ME) & ME > 0]
    portfolio_sample[
      ,
      TOTAL_ME := sum(ME),
      by = .(RETURN_YYYYMM, DECILE)
    ]
    stopifnot(all(is.finite(portfolio_sample$TOTAL_ME)))
    stopifnot(all(portfolio_sample$TOTAL_ME > 0))

    portfolio_sample[, WEIGHT := ME / TOTAL_ME]
    portfolio_returns <- portfolio_sample[
      ,
      .(
        XRET = sum(WEIGHT * XRET_ADJ),
        N_STOCKS = .N,
        WEIGHT_SUM = sum(WEIGHT)
      ),
      by = .(RETURN_YYYYMM, DECILE)
    ]

    stopifnot(
      max(abs(portfolio_returns$WEIGHT_SUM - 1)) < 1e-10
    )
  } else {
    portfolio_returns <- portfolio_sample[
      ,
      .(
        XRET = mean(XRET_ADJ),
        N_STOCKS = .N,
        WEIGHT_SUM = NA_real_
      ),
      by = .(RETURN_YYYYMM, DECILE)
    ]
  }

  portfolio_returns[, `:=`(
    SIGNAL = signal_name,
    TYPE_CODE = type_code,
    PORTFOLIO_TYPE = portfolio_type,
    WEIGHTING = weighting
  )]
  setcolorder(
    portfolio_returns,
    c(
      "SIGNAL",
      "TYPE_CODE",
      "PORTFOLIO_TYPE",
      "WEIGHTING",
      "DECILE",
      "RETURN_YYYYMM",
      "XRET",
      "N_STOCKS",
      "WEIGHT_SUM"
    )
  )
  portfolio_returns
}

# -----------------------------------------------------------------------------
# Construct the five requested sorts independently for each signal.
# -----------------------------------------------------------------------------

portfolio_return_list <- list()
breakpoint_list <- list()
portfolio_list_index <- 0L
breakpoint_list_index <- 0L

for (signal_name in c("BM_CZ", "MOM_CZ", "GP_CZ")) {
  signal_data <- panel[
    YYYYMM >= 196306L & YYYYMM <= 202411L,
    .(
      PERMNO,
      FORMATION_YYYYMM = YYYYMM,
      FORMATION_INDEX = MONTH_INDEX,
      FORMATION_EXCHCD = EXCHCD,
      SIGNAL_VALUE = get(signal_name)
    )
  ]
  signal_data <- signal_data[is.finite(SIGNAL_VALUE)]

  # Monthly sorts use each month's finite signal cross-section.
  monthly_result <- assign_deciles(
    copy(signal_data),
    group_column = "FORMATION_YYYYMM",
    signal_name = signal_name,
    frequency = "MONTHLY"
  )
  breakpoint_list_index <- breakpoint_list_index + 1L
  breakpoint_list[[breakpoint_list_index]] <- monthly_result$breakpoints

  monthly_membership <- monthly_result$assigned[
    ,
    .(
      PERMNO,
      FORMATION_INDEX,
      DECILE_GENERAL,
      DECILE_NYSE
    )
  ]
  monthly_assigned_returns <- merge(
    realized_sample,
    monthly_membership,
    by = c("PERMNO", "FORMATION_INDEX"),
    all = FALSE,
    sort = FALSE
  )

  portfolio_list_index <- portfolio_list_index + 1L
  portfolio_return_list[[portfolio_list_index]] <-
    calculate_portfolio_returns(
      monthly_assigned_returns,
      "DECILE_NYSE",
      signal_name,
      "iii",
      "VW_MONTHLY_NYSE",
      "VW"
    )
  portfolio_list_index <- portfolio_list_index + 1L
  portfolio_return_list[[portfolio_list_index]] <-
    calculate_portfolio_returns(
      monthly_assigned_returns,
      "DECILE_GENERAL",
      signal_name,
      "v",
      "EW_MONTHLY_GENERAL",
      "EW"
    )

  rm(monthly_result, monthly_membership, monthly_assigned_returns)
  invisible(gc())

  # Annual sorts use June signals. Membership is fixed from July through June.
  annual_signal_data <- signal_data[
    FORMATION_YYYYMM %% 100L == 6L
  ]
  annual_signal_data[, SORT_YEAR := FORMATION_YYYYMM %/% 100L]

  annual_result <- assign_deciles(
    annual_signal_data,
    group_column = "SORT_YEAR",
    signal_name = signal_name,
    frequency = "ANNUAL"
  )
  breakpoint_list_index <- breakpoint_list_index + 1L
  breakpoint_list[[breakpoint_list_index]] <- annual_result$breakpoints

  annual_membership <- annual_result$assigned[
    ,
    .(
      PERMNO,
      SORT_YEAR,
      DECILE_GENERAL,
      DECILE_NYSE
    )
  ]
  annual_assigned_returns <- merge(
    realized_sample,
    annual_membership,
    by = c("PERMNO", "SORT_YEAR"),
    all = FALSE,
    sort = FALSE
  )

  portfolio_list_index <- portfolio_list_index + 1L
  portfolio_return_list[[portfolio_list_index]] <-
    calculate_portfolio_returns(
      annual_assigned_returns,
      "DECILE_NYSE",
      signal_name,
      "i",
      "VW_ANNUAL_NYSE",
      "VW"
    )
  portfolio_list_index <- portfolio_list_index + 1L
  portfolio_return_list[[portfolio_list_index]] <-
    calculate_portfolio_returns(
      annual_assigned_returns,
      "DECILE_NYSE",
      signal_name,
      "ii",
      "EW_ANNUAL_NYSE",
      "EW"
    )
  portfolio_list_index <- portfolio_list_index + 1L
  portfolio_return_list[[portfolio_list_index]] <-
    calculate_portfolio_returns(
      annual_assigned_returns,
      "DECILE_GENERAL",
      signal_name,
      "iv",
      "VW_ANNUAL_GENERAL",
      "VW"
    )

  rm(
    signal_data,
    annual_signal_data,
    annual_result,
    annual_membership,
    annual_assigned_returns
  )
  invisible(gc())
}

portfolio_returns <- rbindlist(portfolio_return_list)
breakpoints <- rbindlist(breakpoint_list)
setorder(portfolio_returns, TYPE_CODE, SIGNAL, DECILE, RETURN_YYYYMM)
setorder(
  breakpoints,
  SIGNAL,
  REBALANCE_FREQUENCY,
  BREAKPOINT_UNIVERSE,
  FORMATION_YYYYMM
)

stopifnot(
  uniqueN(
    portfolio_returns,
    by = c("SIGNAL", "PORTFOLIO_TYPE")
  ) == 15L,
  all(portfolio_returns$DECILE %in% 1:10),
  all(is.finite(portfolio_returns$XRET)),
  min(portfolio_returns$RETURN_YYYYMM) == 196307L,
  max(portfolio_returns$RETURN_YYYYMM) == 202412L,
  all(
    portfolio_returns[
      WEIGHTING == "VW",
      abs(WEIGHT_SUM - 1)
    ] < 1e-10
  )
)

portfolio_means <- portfolio_returns[
  ,
  .(
    AVERAGE_XRET = mean(XRET),
    T_MONTHS = .N,
    FIRST_RETURN_YYYYMM = min(RETURN_YYYYMM),
    LAST_RETURN_YYYYMM = max(RETURN_YYYYMM),
    MIN_N_STOCKS = min(N_STOCKS),
    MEDIAN_N_STOCKS = median(N_STOCKS),
    MAX_N_STOCKS = max(N_STOCKS),
    MAX_ABS_WEIGHT_SUM_ERROR = if (WEIGHTING[1L] == "VW") {
      max(abs(WEIGHT_SUM - 1))
    } else {
      NA_real_
    }
  ),
  by = .(SIGNAL, TYPE_CODE, PORTFOLIO_TYPE, WEIGHTING, DECILE)
]
setorder(portfolio_means, TYPE_CODE, SIGNAL, DECILE)

stopifnot(
  nrow(portfolio_means) == 150L,
  all(portfolio_means$T_MONTHS > 0L)
)

# -----------------------------------------------------------------------------
# Save the five requested scatterplots of decile-average excess returns.
# -----------------------------------------------------------------------------

for (type_code in portfolio_types$TYPE_CODE) {
  type_label <- portfolio_types[
    TYPE_CODE == type_code,
    DISPLAY_NAME
  ]
  plot_data <- portfolio_means[TYPE_CODE == type_code]
  y_increment <- 0.001
  y_base <- floor(min(plot_data$AVERAGE_XRET) / y_increment) * y_increment
  y_top <- ceiling(max(plot_data$AVERAGE_XRET) / y_increment) * y_increment

  if (abs(min(plot_data$AVERAGE_XRET) - y_base) < 1e-12) {
    y_base <- y_base - y_increment
  }
  if (abs(max(plot_data$AVERAGE_XRET) - y_top) < 1e-12) {
    y_top <- y_top + y_increment
  }
  y_breaks <- seq(y_base, y_top, by = y_increment)

  portfolio_plot <- ggplot(
    plot_data,
    aes(
      x = DECILE,
      y = AVERAGE_XRET,
      color = SIGNAL,
      group = SIGNAL
    )
  ) +
    geom_point(size = 2.5) +
    scale_color_manual(
      values = signal_colors,
      breaks = names(signal_display_names),
      labels = unname(signal_display_names)
    ) +
    scale_x_continuous(
      breaks = 1:10,
      minor_breaks = NULL,
      limits = c(1, 10)
    ) +
    scale_y_continuous(
      breaks = y_breaks,
      minor_breaks = NULL,
      limits = c(y_base, y_top),
      labels = percent_label,
      expand = expansion(mult = 0)
    ) +
    labs(
      title = type_label,
      x = "Signal decile",
      y = "Average monthly excess return",
      color = "Signal"
    ) +
    theme_minimal(base_size = 12, base_family = "Times New Roman") +
    theme(
      text = element_text(
        family = "Times New Roman",
        color = "black"
      ),
      plot.title = element_text(hjust = 0.5),
      legend.position = "bottom",
      panel.grid.minor = element_blank(),
      panel.border = element_rect(
        color = "darkgray",
        fill = NA,
        linewidth = 0.5
      ),
      plot.background = element_rect(fill = "white", color = NA),
      panel.background = element_rect(fill = "white", color = NA),
      legend.background = element_rect(fill = "white", color = NA)
    )

  ggsave(
    filename = sprintf("figures/3c_%s.png", type_code),
    plot = portfolio_plot,
    width = 8.5,
    height = 5.5,
    dpi = 300,
    bg = "white"
  )
}

# -----------------------------------------------------------------------------
# Construct 15 HML series, inner-match the three signals within each type,
# and estimate constant-only regressions with the requested Newey-West SEs.
# -----------------------------------------------------------------------------

hml_wide <- dcast(
  portfolio_returns[DECILE %in% c(1L, 10L)],
  SIGNAL + TYPE_CODE + PORTFOLIO_TYPE + RETURN_YYYYMM ~ DECILE,
  value.var = "XRET"
)
setnames(hml_wide, c("1", "10"), c("DECILE_1", "DECILE_10"))
hml_wide <- hml_wide[
  is.finite(DECILE_1) & is.finite(DECILE_10)
]
hml_wide[, HML := DECILE_10 - DECILE_1]

stopifnot(
  uniqueN(hml_wide, by = c("SIGNAL", "PORTFOLIO_TYPE")) == 15L,
  anyDuplicated(
    hml_wide,
    by = c("SIGNAL", "PORTFOLIO_TYPE", "RETURN_YYYYMM")
  ) == 0L
)

common_hml_months <- hml_wide[
  ,
  .(N_SIGNALS = uniqueN(SIGNAL)),
  by = .(TYPE_CODE, PORTFOLIO_TYPE, RETURN_YYYYMM)
][N_SIGNALS == 3L]

hml_monthly <- hml_wide[
  common_hml_months,
  on = .(TYPE_CODE, PORTFOLIO_TYPE, RETURN_YYYYMM),
  nomatch = 0L
]
hml_monthly[, N_SIGNALS := NULL]
setorder(hml_monthly, TYPE_CODE, SIGNAL, RETURN_YYYYMM)

stopifnot(
  uniqueN(hml_monthly, by = c("SIGNAL", "PORTFOLIO_TYPE")) == 15L,
  hml_monthly[
    ,
    uniqueN(SIGNAL),
    by = .(TYPE_CODE, RETURN_YYYYMM)
  ][, all(V1 == 3L)]
)

hml_summary <- hml_monthly[
  order(RETURN_YYYYMM),
  {
    direct_average <- mean(HML)
    constant_model <- lm(HML ~ 1)
    selected_bandwidth <- bwNeweyWest(
      constant_model,
      kernel = "Bartlett",
      prewhite = FALSE
    )
    selected_lag <- floor(selected_bandwidth)
    newey_west_vcov <- NeweyWest(
      constant_model,
      lag = selected_lag,
      prewhite = FALSE,
      adjust = FALSE
    )
    intercept <- unname(coef(constant_model)[1L])
    newey_west_se <- sqrt(newey_west_vcov[1L, 1L])

    stopifnot(abs(intercept - direct_average) < 1e-12)

    .(
      T_MONTHS = .N,
      FIRST_RETURN_YYYYMM = min(RETURN_YYYYMM),
      LAST_RETURN_YYYYMM = max(RETURN_YYYYMM),
      DIRECT_AVERAGE_HML = direct_average,
      REGRESSION_INTERCEPT = intercept,
      INTERCEPT_MINUS_DIRECT_AVERAGE = intercept - direct_average,
      NEWEY_WEST_SE = newey_west_se,
      T_STATISTIC = intercept / newey_west_se,
      NEWEY_WEST_BANDWIDTH = selected_bandwidth,
      NEWEY_WEST_LAG = as.integer(selected_lag)
    )
  },
  by = .(SIGNAL, TYPE_CODE, PORTFOLIO_TYPE)
]
setorder(hml_summary, TYPE_CODE, SIGNAL)

stopifnot(
  nrow(hml_summary) == 15L,
  all(is.finite(hml_summary$DIRECT_AVERAGE_HML)),
  all(is.finite(hml_summary$NEWEY_WEST_SE)),
  all(hml_summary$NEWEY_WEST_SE >= 0),
  all(is.finite(hml_summary$T_STATISTIC)),
  max(abs(hml_summary$INTERCEPT_MINUS_DIRECT_AVERAGE)) < 1e-12
)

# -----------------------------------------------------------------------------
# Save requested CSV summaries, detailed reproducibility outputs, and LaTeX.
# -----------------------------------------------------------------------------

fwrite(signal_summary, "code/3c_summary.csv")
fwrite(breakpoints, "code/3c_breakpoints.csv")
fwrite(portfolio_returns, "code/3c_portfolio_returns.csv")
fwrite(portfolio_means, "code/3c_portfolio_means.csv")
fwrite(hml_monthly, "code/3c_hml_monthly.csv")
fwrite(hml_summary, "code/3c_hml_summary.csv")

latex_escape <- function(x) {
  vapply(
    strsplit(x, "_", fixed = TRUE),
    paste,
    collapse = "\\_",
    FUN.VALUE = character(1L)
  )
}

latex_lines <- c(
  "\\begin{table}[H]",
  "  \\centering",
  "  \\caption{HML portfolio results}",
  "  \\label{tab:3c_hml}",
  "  \\begin{tabular}{lrrrrr}",
  "    \\hline",
  paste0(
    "    Signal & Mean HML & Newey--West SE & $t$-statistic ",
    "& Lag & $T$ \\\\"
  ),
  "    \\hline"
)

for (type_code in portfolio_types$TYPE_CODE) {
  table_data <- hml_summary[TYPE_CODE == type_code]
  table_title <- portfolio_types[
    TYPE_CODE == type_code,
    DISPLAY_NAME
  ]

  latex_lines <- c(
    latex_lines,
    sprintf(
      "    \\multicolumn{6}{l}{\\textit{Panel %s: %s}} \\\\",
      type_code,
      latex_escape(table_title)
    )
  )

  for (row_index in seq_len(nrow(table_data))) {
    row <- table_data[row_index]
    latex_lines <- c(
      latex_lines,
      sprintf(
        "    %s & %.6f & %.6f & %.3f & %d & %d \\\\",
        latex_escape(row$SIGNAL),
        row$DIRECT_AVERAGE_HML,
        row$NEWEY_WEST_SE,
        row$T_STATISTIC,
        row$NEWEY_WEST_LAG,
        row$T_MONTHS
      )
    )
  }

  if (type_code != tail(portfolio_types$TYPE_CODE, 1L)) {
    latex_lines <- c(latex_lines, "    \\hline")
  }
}

latex_lines <- c(
  latex_lines,
  "    \\hline",
  "  \\end{tabular}",
  "\\end{table}",
  ""
)

writeLines(latex_lines, "figures/3c_hml.tex", useBytes = TRUE)

# Print the requested summaries for an interactive run as well as saving them.
print(signal_summary)
print(portfolio_means)
print(hml_summary)
