import Foundation

/// A study a calculated metric rests on, listed under "Sources" on its detail screen. DOIs were matched to
/// titles through Crossref; whether each paper says what Grada takes from it is checked in #81.
struct MetricSource: Hashable {
    /// Authors, year and journal, e.g. "Stanley, Peake & Buchheit 2013 · Sports Medicine".
    let citation: String
    /// What Grada takes from it.
    let supports: String
    /// The DOI link, or the publisher's page when there is no DOI. Books have none.
    let url: URL?

    private init(_ citation: String, _ supports: LocalizedStringResource, doi: String? = nil, url: String? = nil) {
        self.citation = citation
        self.supports = String(localized: supports)
        self.url = (doi.map { "https://doi.org/" + $0 } ?? url).flatMap(URL.init(string:))
    }

    // Heart rate and HRV
    static let leMeur2013 = MetricSource("Le Meur et al. 2013 · Med Sci Sports Exerc",
                                         "Half of HRV's usual variation as the smallest change that matters",
                                         doi: "10.1249/mss.0b013e3182980125")
    static let plews2012 = MetricSource("Plews et al. 2012 · Eur J Appl Physiol",
                                        "Tracking the 7-day rolling average of HRV; a full variation below as a warning",
                                        doi: "10.1007/s00421-012-2354-4")
    static let buchheit2014 = MetricSource("Buchheit 2014 · Frontiers in Physiology",
                                           "Reviews both thresholds; no fraction has been validated",
                                           doi: "10.3389/fphys.2014.00073")
    static let kiviniemi2007 = MetricSource("Kiviniemi et al. 2007 · Eur J Appl Physiol",
                                            "Training easy on days HRV falls below its usual range",
                                            doi: "10.1007/s00421-007-0552-2")
    static let mishra2020 = MetricSource("Mishra et al. 2020 · Nature Biomedical Engineering",
                                         "Resting heart rate rising above its personal baseline before symptoms of illness",
                                         doi: "10.1038/s41551-020-00640-6")
    static let tanaka2001 = MetricSource("Tanaka, Monahan & Seals 2001 · J Am Coll Cardiol",
                                         "Max heart rate from age: 208 − 0.7 × age",
                                         doi: "10.1016/s0735-1097(00)01054-8")
    static let garber2011 = MetricSource("Garber et al. 2011 · Med Sci Sports Exerc (ACSM)",
                                         "Effort bands as a share of heart rate reserve",
                                         doi: "10.1249/mss.0b013e318213fefb")
    static let bull2020 = MetricSource("Bull et al. 2020 · Br J Sports Med (WHO guidelines)",
                                       "150 moderate or 75 vigorous minutes a week, so a vigorous minute counts as two",
                                       doi: "10.1136/bjsports-2020-102955")

    // Sleep
    static let watson2015 = MetricSource("Watson et al. 2015 · Sleep (AASM/SRS consensus)",
                                         "Adults up to 60 need at least 7 hours of sleep",
                                         doi: "10.5665/sleep.4716")
    static let hirshkowitz2015 = MetricSource("Hirshkowitz et al. 2015 · Sleep Health (NSF)",
                                              "7–9 hours for adults and 7–8 from 65: at least 7 at every adult age",
                                              doi: "10.1016/j.sleh.2014.12.010")
    static let ohayon2017 = MetricSource("Ohayon et al. 2017 · Sleep Health (NSF consensus)",
                                         "Sleep efficiency, time awake and awakenings that mark good sleep",
                                         doi: "10.1016/j.sleh.2016.11.006")
    static let phillips2017 = MetricSource("Phillips et al. 2017 · Scientific Reports",
                                           "The Sleep Regularity Index",
                                           doi: "10.1038/s41598-017-03171-4")
    static let windred2024 = MetricSource("Windred et al. 2024 · Sleep",
                                          "Typical scores and mortality risk by sleep regularity in 60,000 adults",
                                          doi: "10.1093/sleep/zsad253")
    static let wittmann2006 = MetricSource("Wittmann et al. 2006 · Chronobiology International",
                                           "Sleeping later on free days than on work days is social jetlag",
                                           doi: "10.1080/07420520500545979")
    static let roenneberg2003 = MetricSource("Roenneberg, Wirz-Justice & Merrow 2003 · J Biol Rhythms",
                                             "Free days show how much people sleep without an alarm",
                                             doi: "10.1177/0748730402239679")
    static let roenneberg2012 = MetricSource("Roenneberg et al. 2012 · Current Biology",
                                             "Each hour of social jetlag went with higher odds of overweight",
                                             doi: "10.1016/j.cub.2012.03.038")
    static let banks2010 = MetricSource("Banks et al. 2010 · Sleep",
                                        "One long night isn't enough to recover from a week of short sleep",
                                        doi: "10.1093/sleep/33.8.1013")
    static let depner2019 = MetricSource("Depner et al. 2019 · Current Biology",
                                         "Weekend catch-up sleep didn't undo the harm of short weeknights",
                                         doi: "10.1016/j.cub.2019.01.069")
    static let chinoy2021 = MetricSource("Chinoy et al. 2021 · Sleep",
                                         "Consumer sleep trackers detect time awake poorly",
                                         doi: "10.1093/sleep/zsaa291")
    static let nikbakhtian2021 = MetricSource("Nikbakhtian et al. 2021 · Eur Heart J Digital Health",
                                              "Falling asleep at 22:00–23:00 had the lowest heart disease risk, after midnight the highest",
                                              doi: "10.1093/ehjdh/ztab088")
    static let vanDongen2003 = MetricSource("Van Dongen et al. 2003 · Sleep",
                                            "Deficits keep building over 14 nights of short sleep",
                                            doi: "10.1093/sleep/26.2.117")
    static let kitamura2016 = MetricSource("Kitamura et al. 2016 · Scientific Reports",
                                           "An hour of sleep debt takes days to recover",
                                           doi: "10.1038/srep35812")

    // Training
    static let edwards1993 = MetricSource("Edwards 1993 · The Heart Rate Monitor Book",
                                          "Training load as minutes per heart rate zone, weighted 1 to 5 (TRIMP)")
    static let hulin2016 = MetricSource("Hulin et al. 2016 · Br J Sports Med",
                                        "Comparing the last 7 days' load with the last 28",
                                        doi: "10.1136/bjsports-2015-094817")
    static let gabbett2016 = MetricSource("Gabbett 2016 · Br J Sports Med",
                                          "Lowest injury risk at ratios of 0.8–1.3, highest from 1.5",
                                          doi: "10.1136/bjsports-2015-095788")
    static let impellizzeri2020 = MetricSource("Impellizzeri et al. 2020 · Int J Sports Physiol Perform",
                                               "Why the load ratio is a weak predictor of injury",
                                               doi: "10.1123/ijspp.2019-0864")
    static let foster1998 = MetricSource("Foster 1998 · Med Sci Sports Exerc",
                                         "Training monotony (mean daily load ÷ its standard deviation) and strain (weekly load × monotony)",
                                         doi: "10.1097/00005768-199807000-00023")
    static let foster2001 = MetricSource("Foster et al. 2001 · J Strength Cond Res",
                                         "Session RPE: how hard a workout felt × its minutes, tracking heart rate load",
                                         doi: "10.1519/00124278-200102000-00019")
    static let clemente2019 = MetricSource("Clemente et al. 2019 · PLOS ONE",
                                           "Monotony above 2 as the warning sign, citing Foster",
                                           doi: "10.1371/journal.pone.0225522")
    static let seiler2010 = MetricSource("Seiler 2010 · Int J Sports Physiol Perform",
                                         "Three intensity zones at 82% and 88% of max heart rate; about 80% of training easy",
                                         doi: "10.1123/ijspp.5.3.276")
    static let seilerKjerland2006 = MetricSource("Seiler & Kjerland 2006 · Scand J Med Sci Sports",
                                                 "Three intensity zones from the two ventilatory thresholds",
                                                 doi: "10.1111/j.1600-0838.2004.00418.x")
    static let sylta2014 = MetricSource("Sylta et al. 2014 · Int J Sports Physiol Perform",
                                        "Counted by time, 96% of elite skiers' training was low intensity",
                                        doi: "10.1123/ijspp.2013-0298")
    static let stanley2013 = MetricSource("Stanley, Peake & Buchheit 2013 · Sports Medicine",
                                          "HRV recovers in 24 hours after easy exercise, 24–48 after threshold, 48+ after hard",
                                          doi: "10.1007/s40279-013-0083-4")
    static let danielsGilbert1979 = MetricSource("Daniels & Gilbert 1979 · Oxygen Power",
                                                 "Race times from VO₂ max (Daniels' running formula)")

    // Fitness and lifespan
    static let kaminsky2015 = MetricSource("Kaminsky et al. 2015 · Mayo Clin Proc (FRIEND registry)",
                                           "Lab-measured VO₂ max by age and sex",
                                           doi: "10.1016/j.mayocp.2015.07.026")
    static let ostchega2011 = MetricSource("Ostchega et al. 2011 · National Health Statistics Reports 41",
                                           "Typical resting pulse by age and sex",
                                           url: "https://www.cdc.gov/nchs/data/nhsr/nhsr041.pdf")
    static let finch1990 = MetricSource("Finch, Pike & Witten 1990 · Science",
                                        "Adult risk of dying doubles about every 8 years",
                                        doi: "10.1126/science.2392680")
    static let kodama2009 = MetricSource("Kodama et al. 2009 · JAMA",
                                         "Mortality risk by cardio fitness",
                                         doi: "10.1001/jama.2009.681")
    static let zhang2016 = MetricSource("Zhang et al. 2016 · CMAJ",
                                        "Mortality risk by resting heart rate",
                                        doi: "10.1503/cmaj.150535")
    static let paluch2022 = MetricSource("Paluch et al. 2022 · Lancet Public Health",
                                         "Mortality risk by daily steps",
                                         doi: "10.1016/S2468-2667(21)00302-9")
    static let cappuccio2010 = MetricSource("Cappuccio et al. 2010 · Sleep",
                                            "Mortality risk of short and long sleep; studies drew the lines differently",
                                            doi: "10.1093/sleep/33.5.585")
    static let tudorLocke2018 = MetricSource("Tudor-Locke et al. 2018 · Br J Sports Med",
                                             "Walking at 100 steps a minute is moderate intensity",
                                             doi: "10.1136/bjsports-2017-097628")
    static let cole1999 = MetricSource("Cole et al. 1999 · N Engl J Med",
                                       "Heart rate recovery of 12 bpm or less in the first minute, during a cool-down walk, predicted mortality",
                                       doi: "10.1056/NEJM199910283411804")
    static let watanabe2001 = MetricSource("Watanabe et al. 2001 · Circulation",
                                           "Without a cool-down the cut-off was 18 bpm; recovery still predicted mortality",
                                           doi: "10.1161/circ.104.16.1911")
    static let whelton2018 = MetricSource("Whelton et al. 2018 (2017 ACC/AHA guideline) · Hypertension",
                                          "Blood pressure categories: normal, elevated, stage 1 and stage 2 hypertension",
                                          doi: "10.1161/HYP.0000000000000065")
    static let studenski2011 = MetricSource("Studenski et al. 2011 · JAMA",
                                            "Gait speed and survival in adults 65 and older: 1.0, 0.8 and 0.6 m/s",
                                            doi: "10.1001/jama.2010.1923")
    static let appleMobility2022 = MetricSource("Apple 2022 · Measuring Walking Quality Through iPhone Mobility Metrics",
                                                "How iPhone measures walking speed, step length and asymmetry",
                                                url: "https://www.apple.com/healthcare/docs/site/Measuring_Walking_Quality_Through_iPhone_Mobility_Metrics.pdf")
    static let who2000 = MetricSource("WHO 2000 · Technical Report Series 894",
                                      "BMI classes for adults: underweight, normal, pre-obese and obese",
                                      url: "https://pubmed.ncbi.nlm.nih.gov/11234459/")
    static let arem2015 = MetricSource("Arem et al. 2015 · JAMA Intern Med",
                                       "Mortality risk by weekly exercise",
                                       doi: "10.1001/jamainternmed.2015.0533")

    // Menstrual cycle (#138)
    static let bull2019 = MetricSource("Bull et al. 2019 · npj Digital Medicine",
                                       "Cycle length varies within a person, so the next period is a range, not a date",
                                       doi: "10.1038/s41746-019-0152-7")
    static let marshall1968 = MetricSource("Marshall 1968 · The Lancet",
                                           "The three-over-six rule for a sustained rise in temperature after ovulation",
                                           doi: "10.1016/s0140-6736(68)92886-9")
    static let who1980 = MetricSource("WHO Task Force 1980 · Am J Obstet Gynecol",
                                      "Ovulation followed the first rise in luteinizing hormone by 16–48 hours in 90% of cycles",
                                      url: "https://pubmed.ncbi.nlm.nih.gov/6775535/")
    static let goodale2019 = MetricSource("Goodale et al. 2019 · J Med Internet Res",
                                          "The temperature rise after ovulation shows at the wrist",
                                          doi: "10.2196/13404")
    static let cycle: [MetricSource] = [.bull2019, .marshall1968, .who1980, .goodale2019]
}

extension CardKind {
    /// The studies a calculated metric or its recommendation rests on. Other raw Apple Health readings have none.
    var sources: [MetricSource] {
        switch self {
        case .recovery: [.leMeur2013, .plews2012, .buchheit2014, .watson2015, .hirshkowitz2015]
        case .hrvStatus: [.plews2012, .leMeur2013, .buchheit2014, .kiviniemi2007]
        case .healthAge:
            [.finch1990, .kodama2009, .kaminsky2015, .zhang2016, .ostchega2011, .paluch2022, .cappuccio2010, .arem2015]
        case .sleepNeed: [.watson2015, .hirshkowitz2015, .roenneberg2003, .vanDongen2003, .kitamura2016, .banks2010,
                          .depner2019, .wittmann2006, .roenneberg2012, .nikbakhtian2021, .chinoy2021]
        case .steps: [.tudorLocke2018, .paluch2022]
        case .restingHeartRate: [.mishra2020]
        case .sleepConsistency: [.phillips2017, .windred2024]
        case .sleepScore: [.ohayon2017, .watson2015, .hirshkowitz2015, .phillips2017, .windred2024]
        case .intensityMinutes: [.bull2020, .garber2011, .tanaka2001]
        case .dayIntensity: [.garber2011, .tanaka2001]
        case .strain: [.edwards1993, .hulin2016, .gabbett2016, .impellizzeri2020, .foster1998, .clemente2019, .foster2001, .tanaka2001]
        case .recoveryTime: [.stanley2013, .seiler2010, .tanaka2001]
        case .trainingReadiness: [.ohayon2017, .stanley2013, .plews2012, .gabbett2016, .watson2015, .hirshkowitz2015]
        case .loadFocus: [.seiler2010, .seilerKjerland2006, .sylta2014, .tanaka2001]
        case .vo2Max: [.kaminsky2015]
        case .racePredictor: [.danielsGilbert1979]
        case .heartRateRecovery: [.cole1999, .watanabe2001]
        case .weight: [.who2000]
        case .bloodPressure: [.whelton2018]
        case .mobility: [.studenski2011, .appleMobility2022]
        default: []
        }
    }

    /// What in a calculated metric no study has set, shown as "Grada's estimate" next to the sources.
    var estimateNote: String? {
        switch self {
        case .healthStatus:
            String(localized: "Your normal range is your 30-day average ± 2 standard deviations. How many vitals out of range make Fair or Poor is Grada's choice; no study has set it.")
        case .recovery:
            String(localized: "Each threshold comes from the studies above. Counting inputs off into Good, Fair and Poor is Grada's choice.")
        case .resources:
            String(localized: "No published method estimates energy through the day without beat-to-beat HRV, which iPhone doesn't record. The charge and drain rates are Grada's own, and the colour bands are borrowed from WHOOP.")
        case .sleepScore:
            String(localized: "The indicators come from the studies above. Counting each the same is Grada's choice; the experts didn't weigh them.")
        case .recoveryTime:
            String(localized: "The review grades intensity by physiological thresholds, not heart rate. Judging each workout by its average heart rate, placing the thresholds at 82% and 88% of max heart rate (Seiler's zones) and taking 36 hours for the 24–48 hour range are Grada's choices.")
        case .sleepNeed:
            String(localized: "Your sleep need is the median sleep of your weekend nights over the last \(SleepNeed.learningDays) days, once there are \(SleepNeed.minimumFreeNights). Your usual wake-up and bedtime are the medians of the last \(Bedtime.nights) nights, weekdays and weekends apart once each has \(Bedtime.minimumNights) nights. The bedtime doesn't add time awake in bed, which trackers measure poorly. These windows, and letting a weekend run up to an hour later, are Grada's choices; no study sets them. Paying back at most an hour of sleep debt a night is Grada's choice too.")
        case .restingHeartRate:
            String(localized: "Studies show resting heart rate rising, not a cutoff. Suggesting rest whenever it's above your normal range (30-day average ± 2 standard deviations) is Grada's rule.")
        case .strain:
            String(localized: "Foster counted only training, with rest days at zero; here a day's load is all of its heart rate. Using the sample standard deviation is Grada's choice. Effort load uses Apple's 1–10 effort score for Foster's 0–10 rating scale, and needs \(SessionRPE.minimumRatedWorkouts) rated workouts, Grada's choice.")
        case .weight:
            String(localized: "BMI uses the latest height in Apple Health for every day, since adult height barely changes.")
        case .heartRateRecovery:
            String(localized: "Without Apple Watch's own measurement, taking the reading closest to one minute after the end, at most 15 seconds off, is Grada's choice.")
        case .healthAge:
            String(localized: "Sleep and exercise count by the categories the studies report, so crossing an edge such as 7 hours of sleep or 150 minutes of exercise a week changes the result in one step. The pooled sleep studies drew their lines differently; under 7 and over 8 hours is Grada's reading of their reference.")
        case .trainingReadiness:
            String(localized: "Garmin doesn't publish how it weighs these inputs and no study has tested a weighting, so each counts the same.")
        default: nil
        }
    }
}
