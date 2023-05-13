<?php

/**
 * @copyright Copyright (C) Ibexa AS. All rights reserved.
 * @license For full copyright and license information view LICENSE file distributed with this source code.
 */
declare(strict_types=1);

namespace Ibexa\ContiniousIntegrationScripts\Command;

use CzProject\GitPhp\Git;
use CzProject\GitPhp\GitException;
use Github\Client;
use Ibexa\ContiniousIntegrationScripts\Helper\ComposerLocalTokenProvider;
use JsonException;
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

    /** @var \Github\Client */
    private $githubClient;

    /** @var \CzProject\GitPhp\Git */
    private $repository;

    /** @var \Ibexa\ContiniousIntegrationScripts\Helper\ComposerLocalTokenProvider */
    private $tokenProvider;

    public function __construct()
    {
        parent::__construct();
        $this->githubClient = new Client();
        $this->repository = new Git();
        $this->tokenProvider = new ComposerLocalTokenProvider();
    }

    protected function interact(InputInterface $input, OutputInterface $output): void
    {
        $io = new SymfonyStyle($input, $output);

        if (!$input->getArgument('token')) {
            $input->setArgument('token', $this->tokenProvider->getGitHubToken());
        }

        if (!$input->getArgument('productVersion')) {
            $productVersion = $io->ask(
                'Please enter the Ibexa DXP version',
                '4.5',
                static function (string $answer): string {
                    if (preg_match('/^(\d+)\.(\d+)$/', $answer) === 0) {
                        throw new \RuntimeException(
                            sprintf(
                                'Unrecognised version format: %s. Please use format X.Y instead, e.g. 3.3, 4.4, 4.5',
                                $answer
                            )
                        );
                    }

                    return $answer;
                }
            );

            $input->setArgument('productVersion', $productVersion);
        }

        if (!$input->getArgument('productEditions')) {
            $productEditions = $io->ask('Please enter the Ibexa DXP edition(s)', 'oss', static function (string $answer): array {
                $editions = explode(',', $answer);
                self::validateEditions($editions);

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

        if (!is_array($productEditions)) {
            $productEditions = explode(',', $productEditions);
            $this->validateEditions($productEditions);
        }

        $this->validate();

        $regressionBranchName = uniqid('tmp_regression_', true);

        foreach ($productEditions as $productEdition) {
            $baseBranch = $this->getBaseBranch($productEdition, $productVersion);
            $this->createRegressionPullRequest($productEdition, $baseBranch, $regressionBranchName, $io);
        }

        return Command::SUCCESS;
    }

    private function createRegressionPullRequest(string $productEdition, string $baseBranch, string $regressionBranchName, SymfonyStyle $io): void
    {
        try {
            $repo = $this->repository->cloneRepository(
                sprintf('git@github.com:%s/%s.git', self::REPO_OWNER, $productEdition),
                null,
                ['-b' => $baseBranch]
            );
        } catch (GitException $exception) {
            // fallback to HTTPS if SSH fails
            $repo = $this->repository->cloneRepository(
                sprintf('https://github.com/%s/%s.git', self::REPO_OWNER, $productEdition),
                null,
                ['-b' => $baseBranch]
            );
        }

        $repo->createBranch($regressionBranchName, true);
        $repo->removeBranch($baseBranch);

        copy(LinkDependenciesCommand::DEPENDENCIES_FILE, $productEdition . \DIRECTORY_SEPARATOR . LinkDependenciesCommand::DEPENDENCIES_FILE);

        $repo->addFile(LinkDependenciesCommand::DEPENDENCIES_FILE);
        $repo->commit(self::COMMIT_MESSAGE);
        $repo->push(['origin', $regressionBranchName]);

        $io->success(sprintf('Successfuly pushed to %s/%s a branch called: %s', self::REPO_OWNER, $productEdition, $regressionBranchName));

        if ($this->token) {
            $this->githubClient->authenticate($this->token, null, Client::AUTH_ACCESS_TOKEN);
        }

        $this->waitUntilBranchExists($productEdition, $regressionBranchName);

        $response = $this->githubClient->pullRequests()->create(
            self::REPO_OWNER,
            $productEdition,
            [
                'title' => 'Run regression for IBX-XXXX',
                'base' => $baseBranch,
                'head' => $regressionBranchName,
                'body' => 'Please add your description here.',
                'draft' => 'true',
            ]
        );

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
        } catch (JsonException $e) {
            throw new \RuntimeException(
                sprintf("File '%s' is not a valid JSON.", LinkDependenciesCommand::DEPENDENCIES_FILE)
            );
        }
    }

    private function waitUntilBranchExists(string $productEdition, string $branchName): void
    {
        $counter = 0;
        $success = false;
        while ($counter < 5) {
            try {
                $this->githubClient->repo()->branches(self::REPO_OWNER, $productEdition, $branchName);
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

    private function getBaseBranch(string $productEdition, string $productVersion): string
    {
        try {
            $this->githubClient->repo()->branches(self::REPO_OWNER, $productEdition, $productVersion);

            return $productVersion;
        } catch (\RuntimeException $e) {
            return 'master';
        }
    }

    /**
     * @param iterable<string> $editions
     */
    private static function validateEditions(iterable $editions): void
    {
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
    }
}
