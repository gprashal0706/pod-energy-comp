#' Schedule battery
#'
#' Function that schedules the charging and discharging of a battery at
#' half-hourly intervals to reduce peak demand.
#'
#' The operation of the battery adheres to constraints outlined in the POD data
#' science challenge (2021). Each day of charging and discharging is managed
#' separately with the battery starting from zero charge each day. Any changes
#' in charge must be between -2.5 MW and 2.5 MW. Between periods 1-41 only
#' charging can occur. Discharging can only occur between periods 32-42.
#'
#' To charge the battery, the algorithm loops through each periods between 2 and
#' 41. It takes a proportion of solar PV produced during each half-hourly period
#' such that the total energy sums to the battery capacity. If the total PV
#' energy is less than 6 MWh then additional energy is drawn from the grid to
#' ensure the battery is fully charged.
#'
#' @param data (data frame) Data frame containing the columns datetime, period,
#'   pv_power_mw
#'
#' @return List of matrices showing the battery charges/discharges, cumulative
#'   charge, loads and PV generation.
#' @export
#' 
#' @importFrom tibble column_to_rownames
#' @importFrom lubridate date
#' @importFrom dplyr mutate select 
#' @importFrom tidyr pivot_wider
#' @importFrom rlang .data
schedule_battery <- function(data) {
  fill_missing_periods <- function(x) {
    missing_periods <- c(1:48)[!(1:48 %in% colnames(x))]
    missing_periods <- as.character(missing_periods)
    x_na <- matrix(NA, nrow = nrow(x), ncol = length(missing_periods),
           dimnames = list(rownames(x), missing_periods))
    x <- cbind(x, x_na)
    x <- x[,as.character(1:48)]
    x
  }
  
  date_list <- unique(date(data$datetime))
  data <- data %>% 
    mutate(date = date(.data$datetime))
  P <- data %>%
    select(.data$date, .data$period, .data$pv_power_mw) %>% 
    pivot_wider(id_cols = .data$date, 
                names_from = .data$period, 
                values_from = .data$pv_power_mw) %>% 
    column_to_rownames("date") %>% 
    as.matrix() %>% 
    fill_missing_periods()
  
  L <- data %>% 
    select(.data$date, .data$period, .data$demand_mw) %>% 
    pivot_wider(id_cols = .data$date, 
                names_from = .data$period, 
                values_from = .data$demand_mw) %>% 
    column_to_rownames("date") %>% 
    as.matrix() %>% 
    fill_missing_periods()
  B <- C <- matrix(0, nrow = 7, ncol = 48, dimnames = dimnames(P))
  # FIXME: hard coded schedule index
  c_idx <- 2:31  # charging period indices
  for (iD in as.character(date_list)) {
    # Total solar expected
    P_tot <- sum(P[iD,c_idx])
    # NB: this forces the battery to be fully charged and will take in grid demand
    # if not enough solar. However, score is improved the more the battery is
    # charged so there is no penalty for this.
    sc_fctr <- 12/P_tot
    
    for (iP in c_idx) {
      if (P[iD,iP] > 0) {
        B[iD,iP] <- min(sc_fctr*P[iD, iP], 2.5)
        C[iD,iP+1] <- C[iD,iP] + 0.5*B[iD,iP]  # 0.5 converts MW to MWh
        
        # check constraints
        if (C[iD,iP+1] > 6) {
          B[iD,iP] <- 2*(6 - C[iD,iP])
          C[iD,iP+1] <- 6
        } 
      } else {
        C[iD,iP+1] <- C[iD,iP]
      }
    }
  }
  
  # Discharge battery
  # TODO: Add test to make sure peak profile is concave. Need to figure out what
  # to do if there are sudden dips in probile - not sure this method will work
  # properly. See notes in notebook. NB: I think this will only be an issue if
  # the new peak is higher than the min demand of old profile. If new peak is
  # below old profile all battery discharge values will be negative over d_idx
  # as required. So, can probably just add a test to see if the new peak is
  # above any of the old profile demand values.
  # TODO: Also add tests to make sure constraints aren't violated should
  # non-convex profile be predicted.
  # FIXME: hard coded schedule index
  d_idx <- 32:42  # discharge period indices
  for (iD in as.character(date_list)) {
    # Subtracts 6 MWh from peak giving flat profile over d_idx periods
    new_peak_mw <- (sum(L[iD,d_idx]) - 12)/length(d_idx)
    for (iP in d_idx) {
      if (C[iD,iP] > 0) {
        dschrg_mw <- L[iD,iP] - new_peak_mw
        B[iD,iP] <- -1 * min(2.5, dschrg_mw)
        C[iD,iP+1] <- C[iD,iP] + 0.5*B[iD,iP]
      } else if (C[iD,iP] == 0) {
        # battery completely discharged so move to next day
        B[iD,iP:max(d_idx)] <- C[iD,(iP+1):(max(d_idx)+1)] <- 0
        break
      }
    }
  }
  
  # fill remaining values
  B[,43:48] <- 0
  C[,44:48] <- C[,43]
  
  # round due to numeric precision issues
  C <- round(C,8)

  list("B" = B,
       "C" = C,
       "L" = L,
       "P" = P)
}


#' Format battery charge data
#'
#' Formats battery charge data to required competition format.
#'
#' @param B (matrix) Matrix of half-hourly battery charges/discharges.
#'
#' @return Data frame of battery charges/discharges.
#' @export
#'
#' @importFrom dplyr as_tibble mutate arrange select row_number
#' @importFrom tidyr pivot_longer
#' @importFrom lubridate as_datetime minutes
#' @importFrom rlang .data
format_charge_data <- function(B) {
  B %>% 
    as_tibble(rownames = "date") %>% 
    pivot_longer(cols = -.data$date,
                 names_to = "period", 
                 values_to = "charge_MW") %>% 
    mutate(period = as.numeric(.data$period),
           datetime = as_datetime(.data$date) + minutes(30*(.data$period-1))) %>% 
    arrange(.data$datetime) %>% 
    mutate(`_id` = row_number()) %>% 
    select(.data$`_id`, .data$datetime, .data$charge_MW)
}