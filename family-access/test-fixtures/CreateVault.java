import org.cryptomator.cryptofs.CryptoFileSystem;
import org.cryptomator.cryptofs.CryptoFileSystemProperties;
import org.cryptomator.cryptofs.CryptoFileSystemProvider;
import org.cryptomator.cryptolib.api.CryptorProvider;
import org.cryptomator.cryptolib.api.Masterkey;
import org.cryptomator.cryptolib.api.MasterkeyLoader;
import org.cryptomator.cryptolib.common.MasterkeyFileAccess;

import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.security.SecureRandom;
import java.util.Random;

// Creates the reference Cryptomator vault used by the reader tests.
//
// Run it with the jars from a cryptomator-cli build (cryptofs 2.8.0, cryptolib
// 2.2.0). With nixpkgs, that is `pkgs.cryptomator-cli`; its store path holds
// `share/cryptomator-cli/{mods,libs}`:
//
//   javac -cp "/*:/*" -d classes test-fixtures/CreateVault.java
//   java -cp "classes:/*:/*" CreateVault /tmp/vault \
//     family-access-vault-fixture "vault-sentinel: 6f1c2a7e"
//
// The vault is then copied to test-fixtures/cryptomator-vault and backed up
// into test-fixtures/restic-cryptomator with restic 0.19.1.
public class CreateVault {
    public static void main(String[] args) throws Exception {
        Path dir = Paths.get(args[0]).toAbsolutePath();
        String passphrase = args[1];
        String sentinel = args[2];
        Files.createDirectories(dir);
        SecureRandom random = new SecureRandom();
        MasterkeyFileAccess access = new MasterkeyFileAccess(new byte[0], random);
        Path mkPath = dir.resolve("masterkey.cryptomator");
        MasterkeyLoader loader = keyId -> {
            try {
                if (Files.exists(mkPath)) {
                    return access.load(mkPath, passphrase);
                }
                Masterkey mk = Masterkey.generate(random);
                access.persist(mk, mkPath, passphrase);
                return mk;
            } catch (java.io.IOException e) {
                throw new org.cryptomator.cryptolib.api.MasterkeyLoadingFailedException("write failed", e);
            }
        };
        CryptoFileSystemProperties props = CryptoFileSystemProperties.cryptoFileSystemProperties()
                .withKeyLoader(loader)
                .withCipherCombo(CryptorProvider.Scheme.SIV_GCM)
                .withShorteningThreshold(220)
                .build();
        CryptoFileSystemProvider.initialize(dir, props, URI.create("masterkeyfile:masterkey.cryptomator"));
        try (CryptoFileSystem fs = CryptoFileSystemProvider.newFileSystem(dir, props)) {
            Files.writeString(fs.getPath("/family-access-sentinel.txt"), sentinel, StandardCharsets.UTF_8);
            Files.writeString(fs.getPath("/caf\u00e9.txt"), "nfc name\n", StandardCharsets.UTF_8);
            Files.writeString(fs.getPath("/cafe\u0301.txt"), "nfd name\n", StandardCharsets.UTF_8);
            Files.writeString(fs.getPath("/empty.txt"), "", StandardCharsets.UTF_8);
            Files.write(fs.getPath("/one-byte.bin"), new byte[]{42});
            byte[] chunk = new byte[32768];
            new Random(1L).nextBytes(chunk);
            Files.write(fs.getPath("/exact-chunk.bin"), chunk);
            byte[] chunkPlus = new byte[32769];
            new Random(2L).nextBytes(chunkPlus);
            Files.write(fs.getPath("/chunk-plus-one.bin"), chunkPlus);
            byte[] big = new byte[100_000];
            new Random(3L).nextBytes(big);
            Files.createDirectories(fs.getPath("/documents/nested"));
            Files.write(fs.getPath("/documents/binary.bin"), big);
            Files.writeString(fs.getPath("/documents/hello.txt"), "hello from inside the vault\n", StandardCharsets.UTF_8);
            Files.writeString(fs.getPath("/documents/nested/report.txt"), "nested report\n", StandardCharsets.UTF_8);
            String longFileName = "long-file-" + "abcdefghij".repeat(18) + ".txt";
            Files.writeString(fs.getPath("/documents/" + longFileName), "shortened file name body\n", StandardCharsets.UTF_8);
            String longDirName = "long-dir-" + "klmnopqrst".repeat(18);
            Files.createDirectories(fs.getPath("/" + longDirName));
            Files.writeString(fs.getPath("/" + longDirName + "/inside.txt"), "inside a shortened directory\n", StandardCharsets.UTF_8);
            try {
                Files.createSymbolicLink(fs.getPath("/link-to-hello.txt"), fs.getPath("documents/hello.txt"));
            } catch (Exception e) {
                System.out.println("symlink skipped: " + e);
            }
        }
        System.out.println("created vault at " + dir);
    }
}
