# Rowing Navigator Privacy Policy

Effective date: July 21, 2026  
Operator: **[Enter the operator's official name before publication]**  
Contact: **[Enter the support email address before publication]**

> This is a publication draft based on the current app implementation. Replace all bracketed placeholders, publish this policy at a publicly accessible HTTPS URL, and then enter the URL in the app stores.

## 1. Scope

This Privacy Policy applies to the handling of user information by Rowing Navigator (the “App”).

## 2. Information We Handle

For navigation safety support, boat-to-boat position sharing, practice records, and shared hazard information, the App handles the following information:

1. Precise location information, including latitude, longitude, and GPS accuracy.
2. A name entered by the user before navigation starts. A nickname may be used.
3. Navigation information, including heading, speed, measurement time, boat type, and session identifier.
4. Device status, including battery level and positioning-accuracy information.
5. An anonymous identifier issued by Firebase Authentication.
6. The location, shape, and timestamps of hazards registered or updated by users.
7. Practice records stored on the device, including location, speed, heading, stroke rate, warning status, distance, and split times.
8. Device, interaction, performance, diagnostic, or similar technical information handled by Google Maps and Firebase SDKs for service delivery, abuse prevention, and diagnostics.
9. Team name, fixed invitation code, team membership, and the time of joining.

The App does not collect email addresses, telephone numbers, postal addresses, contacts, photos, microphone audio, advertising IDs, or payment information as part of its app features. Users may use a nickname instead of their real name.

## 3. Purposes of Use

We use the information only for the following purposes:

- Displaying nearby boats and providing predicted-approach warnings.
- Supporting navigation monitoring and displaying communication or GPS problems.
- Sharing and jointly editing temporary hazards and fixed-driftwood information.
- Providing practice records, distance, speed, split times, and GPX/CSV export.
- Rejecting invalid, outdated, or incompatible data.
- Investigating the safety, stability, and defects of the App.

The App does not use the information for advertising, user tracking, or data sales.

## 4. Background Location

When a user starts navigation, the App continues to obtain location information while the screen is off or another app is displayed. This is necessary to continue approach warnings, navigation records, and boat-to-boat position sharing.

Before requesting the operating system's location permission, the App explains the purpose of background location use. The App stops continued location collection and real-time sharing when the user ends navigation.

## 5. Sharing with Other Users

During navigation, the user's entered name, location, heading, speed, boat type, battery level, and related information are displayed only on App devices that joined the same team using the fixed invitation code. Hazard information is also shared within the same team. Team members may add, edit, and delete shared temporary hazards according to the App's rules.

The invitation code does not automatically change and has no automatic expiration. Anyone who knows the code may join the team, so users must not disclose it outside the team.

The App does not guarantee collision avoidance or safety. Users must continue visual checks, verbal communication, and other normal safety procedures.

## 6. Third-Party Services

The App uses the following Google services:

- Firebase Authentication for anonymous authentication.
- Firebase Realtime Database for real-time navigation-position sharing.
- Cloud Firestore for shared hazard editing.
- Firebase App Check to help prevent unauthorized use by non-genuine apps.
- Google Maps Platform for map display.

These services may send information necessary to provide their services to Google. Google's handling of that information is governed by Google's Privacy Policy and the applicable terms for each service.

## 7. Retention

- Entered names and real-time position information are deleted from Firebase Realtime Database when navigation ends or the connection is lost.
- Temporary hazards are retained in Firestore and remain available to the App until a team member manually deletes them.
- Fixed-driftwood update information is retained while operationally necessary as shared safety information.
- Practice records are stored on the user's device until the user deletes them or uninstalls the App.
- The team name and fixed invitation code may remain after an individual account is deleted so that other team members can continue using the team. The deleted account's ownership identifier is anonymized where applicable.
- The anonymous authentication identifier may be retained until the account and related data are deleted or organized.

## 8. Support Form Information

If you contact us through a Google Form, we use the reply email address, inquiry category, team name, display name, and inquiry details you provide to respond to the inquiry.

Google processes and stores form responses through its services. Do not enter invitation codes, passwords, API keys, or unnecessary personal information in the form.

Support records are generally deleted within one year after the inquiry has been resolved.

## 9. Security

The App uses encrypted communications provided by Firebase and Google Maps Platform. Database access is restricted using Firebase Authentication and Firebase Security Rules, and the App stores only information needed for its stated purposes.

## 10. Deletion and Inquiries

From the App's “Privacy and Data” screen, users can delete their Firebase anonymous account, team membership, real-time shared position and boat profile, temporary hazards they created, practice records, and device settings.

The team itself and its fixed invitation code may remain for other team members. The current state of fixed-driftwood information may remain as shared safety information, while the updater's anonymous identifier is anonymized. For active temporary hazards created or edited by the deleted user, the relevant personal identifier is deleted or anonymized as applicable.

If deletion cannot be completed in the App, or if you have questions about data handling, contact:

**[Enter the support email address before publication]**

If deletion fails because of a network problem, restore connectivity and try again, or contact the support address. We may request information necessary to identify the relevant data when processing a deletion request.

## 11. Children

If a minor uses the App, the rules of the relevant organization and, where necessary, a parent or guardian's consent must be followed. The App does not provide advertising or profiling targeted at minors.

## 12. Changes to This Policy

If this policy is revised, we will publish the effective date and the changes on the public policy page. Material changes may also be announced in the App or in the app-store listing.
