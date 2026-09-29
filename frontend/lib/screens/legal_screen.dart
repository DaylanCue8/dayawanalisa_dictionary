import 'package:flutter/material.dart';

import '../services/app_language.dart';
import '../widgets/dayaw_style.dart';
import '../widgets/glass.dart';

/// The app's two notices. "Data and compliance" is covered inside the
/// privacy notice (section 5): Dayaw collects nothing and sends nothing,
/// so a separate compliance page would only repeat it.
enum LegalDocument { privacy, terms }

/// When the notices last changed - shown at the top of both.
const String legalEffectiveDateEn = 'September 29, 2026';
const String legalEffectiveDateFil = 'Setyembre 29, 2026';

/// One titled block of a notice, in both languages.
class LegalSection {
  final IconData icon;
  final String titleEn, titleFil;
  final List<String> bodyEn, bodyFil;
  const LegalSection(
    this.icon,
    this.titleEn,
    this.titleFil,
    this.bodyEn,
    this.bodyFil,
  );
}

extension LegalDocumentText on LegalDocument {
  String title(BuildContext context) => switch (this) {
    LegalDocument.privacy => context.tr('Privacy & Data', 'Privacy at Datos'),
    LegalDocument.terms => context.tr(
      'Terms of Use',
      'Mga Tuntunin ng Paggamit',
    ),
  };

  IconData get icon => switch (this) {
    LegalDocument.privacy => Icons.shield_outlined,
    LegalDocument.terms => Icons.gavel_outlined,
  };

  List<LegalSection> get sections => switch (this) {
    LegalDocument.privacy => _privacySections,
    LegalDocument.terms => _termsSections,
  };
}

const List<LegalSection> _privacySections = [
  LegalSection(
    Icons.phone_android,
    'In short',
    'Sa madaling salita',
    [
      'Dayaw works entirely on your phone. It has no accounts, no ads and '
          'no analytics, and it does not send your photos, text or results '
          'to any server.',
    ],
    [
      'Gumagana ang Dayaw nang buo sa iyong phone. Walang account, walang '
          'ads at walang analytics, at hindi nito ipinapadala ang iyong mga '
          'larawan, teksto o resulta sa anumang server.',
    ],
  ),
  LegalSection(
    Icons.list_alt,
    'What the app uses',
    'Ano ang ginagamit ng app',
    [
      'Camera: only while you scan, to photograph Baybayin writing.',
      'Photos you take: read in the phone\'s memory. The small letter crops '
          'made while reading are deleted as soon as the scan finishes, and '
          'photos are not saved to your gallery.',
      'Text you type: converted on the phone and not stored.',
      'Settings (language, camera and result preferences): saved on your '
          'phone only, so they stay after you close the app.',
      'Motion sensor: only to measure how steady the phone is for '
          'auto-capture. Readings are not stored.',
    ],
    [
      'Kamera: habang nag-i-scan ka lamang, para kunan ng larawan ang '
          'sulat na Baybayin.',
      'Mga larawang kinuha mo: binabasa sa memorya ng phone. Binubura ang '
          'maliliit na crop ng titik pagkatapos ng scan, at hindi '
          'sine-save ang mga larawan sa iyong gallery.',
      'Tekstong tina-type mo: kino-convert sa phone at hindi iniimbak.',
      'Mga setting (lengwahe, kamera at resulta): sa iyong phone lamang '
          'naka-save, para manatili kahit isara ang app.',
      'Motion sensor: para lamang sukatin kung gaano katatag ang phone '
          'para sa awtomatikong pagkuha. Hindi iniimbak ang mga sukat.',
    ],
  ),
  LegalSection(
    Icons.ios_share,
    'What leaves your phone',
    'Ano ang lumalabas sa iyong phone',
    [
      'Nothing, unless you choose Copy or Export. An exported file goes only '
          'where you send it (for example Files, Drive or a chat app), and '
          'that app\'s own privacy policy then applies.',
    ],
    [
      'Wala, maliban kung pipiliin mo ang Kopyahin o I-export. Ang na-export '
          'na file ay mapupunta lamang kung saan mo ito ipadala (halimbawa '
          'Files, Drive o isang chat app), at ang privacy policy ng app na '
          'iyon ang masusunod.',
    ],
  ),
  LegalSection(
    Icons.delete_outline,
    'Keeping and deleting data',
    'Pag-iimbak at pagbura ng datos',
    [
      'Scan results stay in memory only until you start a new scan or close '
          'the app. To remove saved settings, use Settings > Reset settings, '
          'or uninstall the app.',
    ],
    [
      'Nasa memorya lamang ang mga resulta hanggang magsimula ka ng bagong '
          'scan o isara ang app. Para burahin ang mga naka-save na setting, '
          'gamitin ang Mga Setting > I-reset ang mga setting, o i-uninstall '
          'ang app.',
    ],
  ),
  LegalSection(
    Icons.verified_user_outlined,
    'Data and compliance',
    'Datos at pagsunod sa batas',
    [
      'Because Dayaw collects no personal information and keeps nothing '
          'outside your phone, it follows the principles of transparency, '
          'legitimate purpose and proportionality of the Philippine Data '
          'Privacy Act of 2012 (Republic Act No. 10173).',
      'Please ask permission before scanning handwriting that is not '
          'yours, especially if it contains personal information.',
    ],
    [
      'Dahil walang kinokolektang personal na impormasyon ang Dayaw at '
          'walang iniimbak sa labas ng iyong phone, sumusunod ito sa mga '
          'prinsipyo ng transparency, lehitimong layunin at proporsyonalidad '
          'ng Data Privacy Act of 2012 (Republic Act Blg. 10173).',
      'Humingi muna ng pahintulot bago i-scan ang sulat-kamay na hindi sa '
          'iyo, lalo na kung may personal na impormasyon ito.',
    ],
  ),
  LegalSection(
    Icons.update,
    'Changes and contact',
    'Mga pagbabago at pakikipag-ugnayan',
    [
      'If a future version ever sends data off your phone, this notice will '
          'be updated and the app will tell you before it happens.',
      'Dayaw is a capstone project of Leyte Normal University. For '
          'questions, contact the Dayaw project team through the university.',
    ],
    [
      'Kung may bersyon sa hinaharap na magpapadala ng datos palabas ng '
          'iyong phone, ia-update ang abisong ito at sasabihan ka muna ng '
          'app bago ito mangyari.',
      'Ang Dayaw ay capstone project ng Leyte Normal University. Para sa '
          'mga tanong, makipag-ugnayan sa Dayaw project team sa pamamagitan '
          'ng unibersidad.',
    ],
  ),
];

const List<LegalSection> _termsSections = [
  LegalSection(
    Icons.school_outlined,
    'About Dayaw',
    'Tungkol sa Dayaw',
    [
      'Dayaw is a student capstone project of Leyte Normal University for '
          'learning and preserving Baybayin. It is free for personal and '
          'educational use.',
    ],
    [
      'Ang Dayaw ay capstone project ng mga mag-aaral ng Leyte Normal '
          'University para sa pag-aaral at pangangalaga ng Baybayin. Libre '
          'ito para sa personal at pang-edukasyong gamit.',
    ],
  ),
  LegalSection(
    Icons.swap_horiz,
    'Transliteration, not translation',
    'Transliterasyon, hindi pagsasalin',
    [
      'Dayaw converts between Baybayin and Latin letters by sound. It does '
          'not translate the meaning of words between languages.',
    ],
    [
      'Kino-convert ng Dayaw ang Baybayin at titik Latin ayon sa tunog. '
          'Hindi nito isinasalin ang kahulugan ng mga salita sa ibang wika.',
    ],
  ),
  LegalSection(
    Icons.fact_check_outlined,
    'Accuracy',
    'Katumpakan',
    [
      'Recognition and transliteration are automatic and can be wrong - for '
          'example, D/R, E/I and O/U share letters, and handwriting varies. '
          'Always check important results yourself.',
      'Do not rely on Dayaw alone for legal, official or heritage '
          'documentation without a person reviewing the result.',
    ],
    [
      'Awtomatiko ang pagkilala at transliterasyon at maaaring magkamali - '
          'halimbawa, iisang titik ang D/R, E/I at O/U, at iba-iba ang '
          'sulat-kamay. Laging suriin ang mahahalagang resulta.',
      'Huwag umasa lamang sa Dayaw para sa legal, opisyal o pamanang '
          'dokumentasyon nang walang taong sumusuri sa resulta.',
    ],
  ),
  LegalSection(
    Icons.back_hand_outlined,
    'Your content and fair use',
    'Ang iyong nilalaman at wastong paggamit',
    [
      'What you scan, type and export stays yours, and you are responsible '
          'for what you share.',
      'Do not use Dayaw on content you have no right to use, or for any '
          'unlawful purpose.',
    ],
    [
      'Sa iyo pa rin ang ini-scan, tina-type at ine-export mo, at ikaw ang '
          'mananagot sa ibinabahagi mo.',
      'Huwag gamitin ang Dayaw sa nilalamang wala kang karapatang gamitin, '
          'o para sa anumang labag sa batas.',
    ],
  ),
  LegalSection(
    Icons.extension_outlined,
    'Third-party materials',
    'Mga materyales ng iba',
    [
      'Dayaw includes open-source components, such as the Great Vibes font '
          '(SIL Open Font License), each under its own license.',
    ],
    [
      'May kasamang open-source na bahagi ang Dayaw, gaya ng Great Vibes '
          'font (SIL Open Font License), na may kani-kaniyang lisensya.',
    ],
  ),
  LegalSection(
    Icons.info_outline,
    'No warranty and changes',
    'Walang garantiya at mga pagbabago',
    [
      'Dayaw is provided "as is", without warranty. To the extent the law '
          'allows, the project team and the university are not liable for '
          'losses from using it.',
      'These terms may change with new versions of the app. Continuing to '
          'use the app means you accept the current terms.',
    ],
    [
      'Ibinibigay ang Dayaw nang "as is", walang garantiya. Hangga\'t '
          'pinahihintulutan ng batas, hindi mananagot ang project team at ang '
          'unibersidad sa anumang pinsala mula sa paggamit nito.',
      'Maaaring magbago ang mga tuntuning ito sa mga bagong bersyon. Ang '
          'patuloy na paggamit ng app ay nangangahulugang tinatanggap mo ang '
          'kasalukuyang tuntunin.',
    ],
  ),
];

/// Full-page reader for one notice.
class LegalScreen extends StatelessWidget {
  final LegalDocument document;

  const LegalScreen({super.key, required this.document});

  static Future<void> open(BuildContext context, LegalDocument document) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => LegalScreen(document: document),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.paddingOf(context).top + kToolbarHeight;
    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: Text(
          document.title(context),
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        foregroundColor: DayawColors.deepBrown,
        elevation: 0,
        scrolledUnderElevation: 0,
        flexibleSpace: const GlassBar(child: SizedBox.expand()),
      ),
      body: GlassBackground(
        child: ListView(
          padding: EdgeInsets.fromLTRB(
            20,
            topInset + 16,
            20,
            24 + MediaQuery.paddingOf(context).bottom,
          ),
          children: [
            Text(
              context.tr(
                'Effective $legalEffectiveDateEn',
                'Epektibo mula $legalEffectiveDateFil',
              ),
              style: const TextStyle(fontSize: 12.5, color: Colors.black54),
            ),
            const SizedBox(height: 14),
            for (final section in document.sections) ...[
              GlassContainer(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    DayawSectionTitle(
                      context.tr(section.titleEn, section.titleFil),
                      section.icon,
                    ),
                    const SizedBox(height: 8),
                    for (final paragraph
                        in context.tr('en', 'fil') == 'fil'
                            ? section.bodyFil
                            : section.bodyEn)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          paragraph,
                          style: const TextStyle(
                            fontSize: 14,
                            height: 1.45,
                            color: Colors.black87,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],
          ],
        ),
      ),
    );
  }
}
