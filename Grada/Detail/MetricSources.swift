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

    private init(_ citation: String, _ supports: String, doi: String? = nil, url: String? = nil) {
        self.citation = citation
        self.supports = supports
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
    static let tanaka2001 = MetricSource("Tanaka, Monahan & Seals 2001 · J Am Coll Cardiol",
                                         "Max heart rate from age: 208 − 0.7 × age",
                                         doi: "10.1016/s0735-1097(00)01054-8")
    static let garber2011 = MetricSource("Garber et al. 2011 · Med Sci Sports Exerc (ACSM)",
                                         "Effort bands as a share of heart rate reserve",
                                         doi: "10.1249/mss.0b013e318213fefb")
    static let bull2020 = MetricSource("Bull et al. 2020 · Br J Sports Med (WHO guidelines)",
                                       "150 moderate minutes a week, vigorous counting double",
                                       doi: "10.1136/bjsports-2020-102955")

    // Sleep
    static let watson2015 = MetricSource("Watson et al. 2015 · Sleep (AASM/SRS consensus)",
                                         "Adults need at least 7 hours of sleep",
                                         doi: "10.5665/sleep.4716")
    static let ohayon2017 = MetricSource("Ohayon et al. 2017 · Sleep Health (NSF consensus)",
                                         "Sleep efficiency, time awake and awakenings that mark good sleep",
                                         doi: "10.1016/j.sleh.2016.11.006")
    static let phillips2017 = MetricSource("Phillips et al. 2017 · Scientific Reports",
                                           "The Sleep Regularity Index",
                                           doi: "10.1038/s41598-017-03171-4")
    static let windred2024 = MetricSource("Windred et al. 2024 · Sleep",
                                          "Typical scores and mortality risk by sleep regularity in 60,000 adults",
                                          doi: "10.1093/sleep/zsad253")
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
    static let arem2015 = MetricSource("Arem et al. 2015 · JAMA Intern Med",
                                       "Mortality risk by weekly exercise",
                                       doi: "10.1001/jamainternmed.2015.0533")
}

extension CardKind {
    /// The studies a calculated metric rests on. Raw Apple Health readings have none.
    var sources: [MetricSource] {
        switch self {
        case .recovery: [.leMeur2013, .plews2012, .buchheit2014, .watson2015]
        case .hrvStatus: [.plews2012, .leMeur2013, .buchheit2014]
        case .healthAge:
            [.finch1990, .kodama2009, .kaminsky2015, .zhang2016, .ostchega2011, .paluch2022, .cappuccio2010, .arem2015]
        case .sleepNeed: [.watson2015, .vanDongen2003, .kitamura2016]
        case .sleepConsistency: [.phillips2017, .windred2024]
        case .sleepScore: [.ohayon2017, .watson2015, .phillips2017, .windred2024]
        case .intensityMinutes: [.bull2020, .garber2011, .tanaka2001]
        case .dayIntensity: [.garber2011, .tanaka2001]
        case .strain: [.edwards1993, .hulin2016, .gabbett2016, .impellizzeri2020, .tanaka2001]
        case .recoveryTime: [.stanley2013, .seiler2010, .tanaka2001]
        case .trainingReadiness: [.ohayon2017, .stanley2013, .plews2012, .gabbett2016, .watson2015]
        case .loadFocus: [.seiler2010, .seilerKjerland2006, .sylta2014, .tanaka2001]
        case .vo2Max: [.kaminsky2015]
        case .racePredictor: [.danielsGilbert1979]
        default: []
        }
    }

    /// What in a calculated metric no study has set, shown as "Grada's estimate" next to the sources.
    var estimateNote: String? {
        switch self {
        case .healthStatus:
            "Your normal range is your 30-day average ± 2 standard deviations. How many vitals out of range make Fair or Poor is Grada's choice; no study has set it."
        case .recovery:
            "Each threshold comes from the studies above. Counting inputs off into Good, Fair and Poor is Grada's choice."
        case .resources:
            "No published method estimates energy through the day without beat-to-beat HRV, which iPhone doesn't record. The charge and drain rates are Grada's own, and the colour bands are borrowed from WHOOP."
        case .sleepScore:
            "The indicators come from the studies above. Counting each the same is Grada's choice; the experts didn't weigh them."
        case .recoveryTime:
            "The review grades intensity by physiological thresholds, not heart rate. Placing them at 82% and 88% of max heart rate (Seiler's zones) and taking 36 hours for the 24–48 hour range are Grada's choices."
        case .trainingReadiness:
            "Garmin doesn't publish how it weighs these inputs and no study has tested a weighting, so each counts the same."
        default: nil
        }
    }
}
