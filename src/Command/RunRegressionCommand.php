<?php

/**
 * @copyright Copyright (C) Ibexa AS. All rights reserved.
 * @license For full copyright and license information view LICENSE file distributed with this source code.
 */
declare(strict_types=1);

namespace Ibexa\Platform\ContiniousIntegrationScripts\Command;

use Cz\Git\GitException;
use JsonException;
use Cz\Git\GitRepository;
use Github\Client;
use Ibexa\Platform\ContiniousIntegrationScripts\Helper\ComposerHelper;
use Symfony\Component\Console\Command\Command;
use Symfony\Component\Console\Input\InputArgument;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Output\OutputInterface;
use Symfony\Component\Console\Style\SymfonyStyle;
use Symfony\Component\Filesystem\Filesystem;

class RunRegressionCommand extends Command
{
    private const REPO_OWNER = 'ibexa';

    private const COMMIT_MESSAGE = '[TMP] Run regression';

    private const PRODUCT_EDITIONS = ['oss', 'content', 'experience', 'commerce'];

    /** @var ?string */
    private $token;

    protected function interact(InputInterface $input, OutputInterface $output): void
    {
        $io = new SymfonyStyle($input, $output);

        if (!$input->getArgument('token')) {
            $input->setArgument('token', ComposerHelper::getGitHubToken());
        }

        if (!$input->getArgument('productVersion')) {
            $productVersion = $io->ask('Please enter the Ibexa DXP version', '4.1', static function (string $answer): string {
                if (preg_match('/^(\d+)\.(\d+)$/', $answer) === 0) {
                    throw new \RuntimeException(
                        sprintf(
                            'Unrecognised version format: %s. Please use format X.Y instead, e.g. 3.3, 4.0, 4.1',
                        $answer)
                    );
                }

                return $answer;
            });

            $input->setArgument('productVersion', $productVersion);
        }

        if (!$input->getArgument('productEditions')) {
            $productEditions = $io->ask('Please enter the Ibexa DXP edition(s)', 'oss', static function (string $answer): array {
                $editions = explode(',', $answer);
                foreach ($editions as $edition) {
                    if (!in_array($edition, self::PRODUCT_EDITIONS)) {
                        throw new \RuntimeException(
                            sprintf(
                                'Unrecognised edition: %s. Please choose one of: %s',
                                $edition,
                                implode(',', self::PRODUCT_EDITIONS)
                            )
                        );
                    }
                }

                return $editions;
            });

            $input->setArgument('productEditions', $productEditions);
        }
    }

    public function execute(InputInterface $input, OutputInterface $output): int
    {
        $io = new SymfonyStyle($input, $output);
        $this->token = $input->getArgument('token');
        $productVersion = $input->getArgument('productVersion');
        $productEditions = $input->getArgument('productEditions');

        $this->validate();

        $baseBranch = $this->getBaseBranch($productVersion);
        $regressionBranchName = uniqid('tmp_regression_', true);

        foreach ($productEditions as $productEdition) {
            $this->createRegressionPullRequest($productEdition, $baseBranch, $regressionBranchName, $io);
        }

        return Command::SUCCESS;
    }

    private function createRegressionPullRequest(string $productEdition, string $baseBranch, string $regressionBranchName, SymfonyStyle $io): void
    {
        try {
            $repo = GitRepository::cloneRepository(
                sprintf('git@github.com:%s/%s.git', self::REPO_OWNER, $productEdition),
                null, ['-b' => $baseBranch]
            );
        } catch (GitException $exception) {
            // fallback to HTTPS if SSH fails
            $repo = GitRepository::cloneRepository(
                sprintf('https://github.com/%s/%s.git', self::REPO_OWNER, $productEdition),
                null, ['-b' => $baseBranch]
            );
        }

        $repo->createBranch($regressionBranchName, true);
        $repo->removeBranch($baseBranch);

        copy(LinkDependenciesCommand::DEPENDENCIES_FILE, $productEdition . \DIRECTORY_SEPARATOR . LinkDependenciesCommand::DEPENDENCIES_FILE);

        $repo->addFile(LinkDependenciesCommand::DEPENDENCIES_FILE);
        $repo->commit(self::COMMIT_MESSAGE);
        $repo->push('origin', [$regressionBranchName, '-u']);

        $io->success(sprintf('Successfuly pushed to %s/%s a branch called: %s', self::REPO_OWNER, $productEdition, $regressionBranchName));

        $client = new Client();
        if ($this->token) {
            $client->authenticate($this->token, null, Client::AUTH_ACCESS_TOKEN);
        }

        $this->waitUntilBranchExists($client, $productEdition, $regressionBranchName);

        $response = $client->pullRequests()->create(self::REPO_OWNER, $productEdition,
            [
                'title' => 'Run regression for IBX-XXXX',
                'base' => $baseBranch,
                'head' => $regressionBranchName,
                'body' => 'Please add your description here.',
                'draft' => 'true',
            ]);

        $io->success(sprintf('Created PR, please see: %s', $response['_links']['html']['href']));

        if ($io->confirm(sprintf('Do you want to remove the created %s directory?', $productEdition), true)) {
            $fs = new Filesystem();
            $fs->remove($productEdition);
        }
    }

    protected function configure(): void
    {
        $this
            ->setName('regression:run')
            ->setDescription('Triggers a regression run on Travis')
            ->addArgument('productVersion', InputArgument::REQUIRED, 'Ibexa DXP version')
            ->addArgument('productEditions', InputArgument::REQUIRED, 'Ibexa DXP edition')
            ->addArgument('token', InputArgument::OPTIONAL, 'GitHub token')
        ;
    }

    private function validate(): void
    {
        if (!file_exists(LinkDependenciesCommand::DEPENDENCIES_FILE)) {
            throw new \RuntimeException(
                sprintf("File '%s' not found. Please run the `dependencies:link` Command before running this one.", LinkDependenciesCommand::DEPENDENCIES_FILE)
            );
        }

        $dependenciesFile = file_get_contents(LinkDependenciesCommand::DEPENDENCIES_FILE);
        if ($dependenciesFile === false) {
            throw new \RuntimeException(
                sprintf('Unable to read the %s file', LinkDependenciesCommand::DEPENDENCIES_FILE)
            );
        }

        try {
            json_decode($dependenciesFile, true, 512, JSON_THROW_ON_ERROR);
        }
        catch (JsonException $e)
        {
            throw new \RuntimeException(
                sprintf("File '%s' is not a valid JSON.", LinkDependenciesCommand::DEPENDENCIES_FILE)
            );
        }
    }

    private function waitUntilBranchExists(Client $client, string $productEdition, string $branchName): void
    {
        $counter = 0;
        $success = false;
        while ($counter < 5) {
            try {
                $client->repo()->branches(self::REPO_OWNER, $productEdition, $branchName);
                $success = true;
                break;
            } catch (\RuntimeException $e) {
                sleep(1);
                ++$counter;
            }
        }

        if (!$success) {
            throw new \RuntimeException('Pushed branch not found using GitHub API.');
        }
    }

    private function getBaseBranch(string $productVersion): string
    {
        return $productVersion === "4.1" ? "master" : $productVersion;
    }
}
